import DiscDrive
import Foundation

/// Rips one track: reads sectors (securely if configured), applies sample
/// offset correction with zero-fill at disc edges, streams audio into a
/// staging WAV, and computes checksums on the corrected stream.
///
/// Secure-mode design notes (after cdparanoia/EAC/dbpoweramp):
/// - Compare mode makes two *full separated passes* over the track (a track
///   is far larger than any drive cache), then settles the sectors that
///   differ by voting (`Settler`).
/// - C2 mode trusts the drive's error pointers for triage (single pass),
///   only after `DiscRipper` has probed that the C2 data is real — and keeps
///   watching the flag rate, because some drives lie intermittently.
/// - Damaged regions are crossed by `ResilientReader`, which budgets failing
///   device contacts rather than sectors.
public struct TrackRipper: Sendable {
    let device: any CDDeviceIO
    let config: RipConfiguration
    /// Readable sector bounds of the audio area (0 ..< lead-out LBA).
    let readableSectors: Range<Int>
    let useC2: Bool
    let damage: DamageMap

    private static let bytesPerSector = SectorAreas.audioBytesPerSector

    public init(
        device: any CDDeviceIO,
        configuration: RipConfiguration,
        readableSectors: Range<Int>,
        useC2: Bool,
        damage: DamageMap = DamageMap()
    ) {
        self.device = device
        self.config = configuration
        self.readableSectors = readableSectors
        self.useC2 = useC2
        self.damage = damage
    }

    /// Thrown when the drive's C2 flag rate is implausible — the track must
    /// be restarted in compare mode and C2 retired for this drive.
    struct C2DistrustError: Error {}

    /// The secure engine's knobs, present only in secure mode.
    private struct SecureParams {
        let maxRetries: Int
        let agreeingPasses: Int
    }

    private struct TrackContext {
        let track: TOCTrack
        let sectors: Range<Int>
        let trackByteStart: Int
        let wavURL: URL
        let secure: SecureParams?
        var checksums: ChecksumAccumulator
        let onAudio: ((Data) -> Void)?
        let progress: (RipProgress) -> Void

        /// Corrected byte window of a run of output sectors.
        func window(ofOutputSectors sectors: Range<Int>) -> Range<Int> {
            let bps = TrackRipper.bytesPerSector
            return (trackByteStart + sectors.lowerBound * bps) ..< (trackByteStart + sectors.upperBound * bps)
        }

        /// Corrected byte window of one output sector.
        func window(ofOutputSector index: Int) -> Range<Int> {
            window(ofOutputSectors: index ..< index + 1)
        }
    }

    private var reader: ResilientReader {
        ResilientReader(
            device: device,
            readableSectors: readableSectors,
            maxRequestSectors: config.chunkSectors,
            damage: damage
        )
    }

    public func rip(
        track: TOCTrack,
        toc: TOC,
        position: TrackPosition,
        to wavURL: URL,
        onAudio: ((Data) -> Void)? = nil,
        progress: @escaping (RipProgress) -> Void
    ) async throws -> RippedTrack {
        let sectors = toc.sectorRange(of: track)
        let secure: SecureParams? = if case .secure(let maxRetries, let agreeingPasses) = config.mode {
            SecureParams(maxRetries: maxRetries, agreeingPasses: agreeingPasses)
        } else {
            nil
        }
        let context = TrackContext(
            track: track,
            sectors: sectors,
            trackByteStart: sectors.lowerBound * Self.bytesPerSector + config.sampleOffset * 4,
            wavURL: wavURL,
            secure: secure,
            checksums: ChecksumAccumulator(
                totalSamples: sectors.count * SectorAreas.samplesPerSector, position: position
            ),
            onAudio: onAudio,
            progress: progress
        )

        let health = RipHealth(deadline: config.trackTimeLimit.map { ContinuousClock.now + $0 })
        let result: RippedTrack
        if let secure {
            if useC2 {
                do {
                    result = try await singlePassRip(context, health: health)
                } catch is C2DistrustError {
                    // The drive's C2 lied mid-track: restart this track in
                    // compare mode with fresh state.
                    result = try await twoPassCompareRip(context, secure: secure, health: health, c2Unreliable: true)
                }
            } else {
                result = try await twoPassCompareRip(context, secure: secure, health: health, c2Unreliable: false)
            }
        } else {
            result = try await singlePassRip(context, health: health)
        }

        // Restore the configured speed if a damaged region slowed us down.
        if await health.slowed {
            try? await device.setSpeed(config.speedKBps ?? 0xFFFF)
        }
        return result
    }

    // MARK: Chunk walk shared by every pass

    private struct ChunkResult {
        var audio: Data
        var rereads: Int
        var unrecoverableSectors: [Int]
    }

    /// Walks the track in `config.chunkSectors` pieces. Cancellation and
    /// deadline checks, the corrected byte window, the device read and the
    /// progress report are the same for every pass; `body` returns the
    /// re-read count to show in the progress report.
    private func forEachChunk(
        _ context: TrackContext,
        health: RipHealth,
        withC2: Bool,
        progressOffset: Int,
        progressTotal: Int,
        _ body: (_ outputSector: Int, _ result: ChunkResult) async throws -> Int
    ) async throws {
        let totalSectors = context.sectors.count
        var outputSector = 0
        while outputSector < totalSectors {
            try Task.checkCancellation()
            try await health.checkDeadline()
            let chunk = min(config.chunkSectors, totalSectors - outputSector)
            let byteRange = context.window(ofOutputSectors: outputSector ..< outputSector + chunk)
            let result = try await readChunk(for: byteRange, health: health, c2: withC2 ? context.secure : nil)
            let rereads = try await body(outputSector, result)
            outputSector += chunk
            context.progress(RipProgress(
                trackNumber: context.track.number,
                sectorsCompleted: progressOffset + outputSector,
                totalSectors: progressTotal,
                rereads: rereads
            ))
        }
    }

    // MARK: Burst and C2 single-pass path

    private func singlePassRip(_ context: TrackContext, health: RipHealth) async throws -> RippedTrack {
        var context = context
        let totalSectors = context.sectors.count
        let writer = try WAVWriter(url: context.wavURL, expectedDataBytes: totalSectors * Self.bytesPerSector)
        defer { writer.abandonIfOpen() }
        var rereads = 0
        var unrecoverable: [Int] = []

        try await forEachChunk(
            context, health: health, withC2: useC2, progressOffset: 0, progressTotal: totalSectors
        ) { _, result in
            rereads += result.rereads
            unrecoverable.append(contentsOf: result.unrecoverableSectors)
            try writer.append(result.audio)
            context.checksums.update(result.audio)
            context.onAudio?(result.audio)
            return rereads
        }

        try writer.finish()
        return RippedTrack(
            trackNumber: context.track.number,
            wavURL: context.wavURL,
            checksums: context.checksums.finalize(),
            rereads: rereads,
            unrecoverableSectors: unrecoverable.sorted(),
            usedC2: useC2
        )
    }

    // MARK: Compare-mode two-pass path

    /// Pass 1 writes the track; pass 2 re-reads everything and compares
    /// per-sector CRCs. Sectors that differ between passes are settled by
    /// voting and patched into the WAV. Checksums come from the final file.
    private func twoPassCompareRip(
        _ context: TrackContext, secure: SecureParams, health: RipHealth, c2Unreliable: Bool
    ) async throws -> RippedTrack {
        var context = context
        var unrecoverable = Set<Int>()

        let sectorCRCs = try await writePass(context, health: health, unrecoverable: &unrecoverable)

        // Force the second pass to the medium even for tracks smaller than
        // the drive cache.
        await reader.flushCache(near: context.sectors.lowerBound)

        let (patched, rereads) = try await comparePass(
            context, against: sectorCRCs, secure: secure, health: health, unrecoverable: &unrecoverable
        )

        // Checksums over the final audio. Pass 1 could have accumulated them
        // on the fly, but patched sectors would invalidate that; re-reading
        // the file costs a fraction of a second.
        try checksumFile(&context, patched: patched)

        return RippedTrack(
            trackNumber: context.track.number,
            wavURL: context.wavURL,
            checksums: context.checksums.finalize(),
            rereads: rereads,
            unrecoverableSectors: unrecoverable.sorted(),
            usedC2: false,
            c2Unreliable: c2Unreliable
        )
    }

    /// Pass 1: writes the WAV and returns a CRC per output sector.
    private func writePass(
        _ context: TrackContext, health: RipHealth, unrecoverable: inout Set<Int>
    ) async throws -> [UInt32] {
        let totalSectors = context.sectors.count
        let writer = try WAVWriter(url: context.wavURL, expectedDataBytes: totalSectors * Self.bytesPerSector)
        defer { writer.abandonIfOpen() }
        var sectorCRCs = [UInt32]()
        sectorCRCs.reserveCapacity(totalSectors)
        var bad = Set<Int>()

        try await forEachChunk(
            context, health: health, withC2: false, progressOffset: 0, progressTotal: totalSectors * 2
        ) { _, result in
            bad.formUnion(result.unrecoverableSectors)
            try writer.append(result.audio)
            for sector in Self.sectorSlices(of: result.audio) {
                sectorCRCs.append(CRC32.checksum(sector))
            }
            return 0
        }
        try writer.finish()
        unrecoverable.formUnion(bad)
        return sectorCRCs
    }

    /// Pass 2: re-reads, compares against pass 1, settles mismatches by
    /// voting and patches them into the WAV. Returns whether anything was
    /// patched and the number of re-reads spent.
    private func comparePass(
        _ context: TrackContext,
        against sectorCRCs: [UInt32],
        secure: SecureParams,
        health: RipHealth,
        unrecoverable: inout Set<Int>
    ) async throws -> (patched: Bool, rereads: Int) {
        let totalSectors = context.sectors.count
        let patcher = try FileHandle(forWritingTo: context.wavURL)
        defer { try? patcher.close() }
        var rereads = 0
        var patched = false
        var bad = Set<Int>()

        try await forEachChunk(
            context, health: health, withC2: false, progressOffset: totalSectors, progressTotal: totalSectors * 2
        ) { outputSector, result in
            for (offset, secondRead) in Self.sectorSlices(of: result.audio).enumerated() {
                let index = outputSector + offset
                guard CRC32.checksum(secondRead) != sectorCRCs[index] else { continue }

                let settled = try await settleWindow(
                    context.window(ofOutputSector: index),
                    initialCandidate: secondRead,
                    secure: secure,
                    health: health
                )
                rereads += settled.rereads
                if !settled.recovered {
                    bad.insert(context.sectors.lowerBound + index)
                }
                try patcher.seek(toOffset: UInt64(WAVWriter.headerSize + index * Self.bytesPerSector))
                try patcher.write(contentsOf: settled.audio)
                patched = true
            }
            return rereads
        }
        unrecoverable.formUnion(bad)
        return (patched, rereads)
    }

    /// Streams the finished WAV through the checksum accumulator (and the
    /// disc-level tap).
    private func checksumFile(_ context: inout TrackContext, patched: Bool) throws {
        let reader = try FileHandle(forReadingFrom: context.wavURL)
        defer { try? reader.close() }
        try reader.seek(toOffset: UInt64(WAVWriter.headerSize))
        while let data = try reader.read(upToCount: 4 << 20), !data.isEmpty {
            context.checksums.update(data)
            context.onAudio?(data)
        }
    }

    /// The 2352-byte sector slices of a chunk of audio (no copies).
    private static func sectorSlices(of audio: Data) -> [Data] {
        stride(from: audio.startIndex, to: audio.endIndex, by: bytesPerSector).map { start in
            audio[start ..< start + bytesPerSector]
        }
    }

    // MARK: Chunk reads

    /// Returns the bytes of the virtual disc byte stream for `byteRange`,
    /// zero-filled where the range falls outside the readable sector bounds.
    /// With `c2` set, the drive's error pointers are requested and flagged
    /// sectors are settled inline.
    private func readChunk(for byteRange: Range<Int>, health: RipHealth, c2: SecureParams?) async throws -> ChunkResult {
        let span = SectorSpan(covering: byteRange, readableSectors: readableSectors)
        guard !span.readable.isEmpty else {
            return ChunkResult(audio: Data(count: byteRange.count), rereads: 0, unrecoverableSectors: [])
        }

        let read: ChunkResult
        if let secure = c2 {
            read = try await readWithC2(sectors: span.readable, secure: secure, health: health)
        } else {
            let resilient = try await reader.read(span.readable, areas: .user, health: health)
            read = ChunkResult(audio: resilient.data, rereads: 0, unrecoverableSectors: resilient.unrecoverable)
        }
        return ChunkResult(
            audio: span.window(fromReadableAudio: read.audio),
            rereads: read.rereads,
            unrecoverableSectors: read.unrecoverableSectors
        )
    }

    private func readWithC2(sectors: Range<Int>, secure: SecureParams, health: RipHealth) async throws -> ChunkResult {
        let areas: SectorAreas = [.user, .errorFlags]
        let resilient = try await reader.read(sectors, areas: areas, health: health)
        let buffer = SectorBuffer(sectorCount: sectors.count, areas: areas, data: resilient.data)

        // Sanity-check the flag rate before acting on a single flag: an
        // implausible rate means the drive's C2 is lying, and settling
        // lie-flagged sectors would grind the mechanism for nothing.
        let flagged = buffer.c2FlaggedSectors()
        if await health.noteC2(flagged: flagged.count, of: sectors.count) {
            throw C2DistrustError()
        }

        var audio = Data(capacity: sectors.count * Self.bytesPerSector)
        var rereads = 0
        var unrecoverable = Set(resilient.unrecoverable)

        for index in 0 ..< sectors.count {
            let lba = sectors.lowerBound + index
            // Sectors zero-filled by the resilient read are already reported.
            if flagged.contains(index), !unrecoverable.contains(lba) {
                let settled = try await settleSector(lba: lba, secure: secure, health: health)
                rereads += settled.rereads
                if !settled.recovered { unrecoverable.insert(lba) }
                audio.append(settled.audio)
            } else {
                audio.append(buffer.audio(sector: index))
            }
        }
        return ChunkResult(audio: audio, rereads: rereads, unrecoverableSectors: unrecoverable.sorted())
    }

    // MARK: Settling

    /// Re-reads a single device sector (C2 path) until clean reads agree.
    private func settleSector(lba: Int, secure: SecureParams, health: RipHealth) async throws -> SettledData {
        try await Settler(reader: reader).settle(
            maxRetries: secure.maxRetries,
            agreeingPasses: secure.agreeingPasses,
            health: health,
            placeholder: Data(count: Self.bytesPerSector),
            flushNear: lba
        ) {
            guard let buffer = try? await device.readSectors(lba ..< lba + 1, areas: [.user, .errorFlags]),
                  !buffer.hasC2Error(sector: 0)
            else { return nil }
            return buffer.audio(sector: 0)
        }
    }

    /// Settles one corrected output-sector window (compare path): re-reads
    /// its input span until identical windows agree.
    private func settleWindow(
        _ byteRange: Range<Int>, initialCandidate: Data, secure: SecureParams, health: RipHealth
    ) async throws -> SettledData {
        let span = SectorSpan(covering: byteRange, readableSectors: readableSectors)
        return try await Settler(reader: reader).settle(
            maxRetries: secure.maxRetries,
            agreeingPasses: secure.agreeingPasses,
            health: health,
            initialCandidate: initialCandidate,
            placeholder: Data(count: byteRange.count),
            flushNear: max(span.sectors.lowerBound, readableSectors.lowerBound)
        ) {
            if span.readable.isEmpty { return span.window(fromReadableAudio: Data()) }
            guard let buffer = try? await device.readSectors(span.readable, areas: .user) else { return nil }
            return span.window(fromReadableAudio: buffer.allAudio())
        }
    }
}
