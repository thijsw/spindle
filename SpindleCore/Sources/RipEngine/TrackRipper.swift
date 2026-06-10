import DiscDrive
import Foundation

/// Rips one track: reads sectors (securely if configured), applies sample
/// offset correction with zero-fill at disc edges, streams audio into a
/// staging WAV, and computes checksums on the corrected stream.
///
/// Secure-mode design notes (after cdparanoia/EAC/dbpoweramp):
/// - Drives cache audio reads, and an immediate re-read of the same sectors
///   is served from that cache — identical garbage twice looks "verified".
///   Compare mode therefore makes two *full separated passes* over the track
///   (a track is far larger than any drive cache), and every targeted
///   re-read is preceded by a cache-busting read on the far side of the
///   disc so it must come from the medium.
/// - C2 mode trusts the drive's error pointers for triage (single pass),
///   which is only enabled after `DiscRipper.probeC2` has validated that the
///   drive's C2 data is real.
public struct TrackRipper: Sendable {
    let device: any CDDeviceIO
    let config: RipConfiguration
    /// Readable sector bounds of the audio area (0 ..< lead-out LBA).
    let readableSectors: Range<Int>
    let useC2: Bool

    private static let bytesPerSector = SectorAreas.audioBytesPerSector

    public init(device: any CDDeviceIO, config: RipConfiguration, readableSectors: Range<Int>, useC2: Bool) {
        self.device = device
        self.config = config
        self.readableSectors = readableSectors
        self.useC2 = useC2
    }

    public func rip(
        track: TOCTrack,
        toc: TOC,
        isFirstAudio: Bool,
        isLastAudio: Bool,
        ctdbLeadingSkip: Int = 0,
        ctdbTrailingSkip: Int = 0,
        to wavURL: URL,
        onAudio: (@Sendable (Data) -> Void)? = nil,
        progress: @Sendable @escaping (RipProgress) -> Void
    ) async throws -> RippedTrack {
        let sectors = toc.sectorRange(of: track)
        let context = TrackContext(
            track: track,
            sectors: sectors,
            trackByteStart: sectors.lowerBound * Self.bytesPerSector + config.sampleOffset * 4,
            wavURL: wavURL,
            checksums: ChecksumAccumulator(
                totalSamples: sectors.count * 588,
                isFirstTrack: isFirstAudio,
                isLastTrack: isLastAudio,
                ctdbLeadingSkip: ctdbLeadingSkip,
                ctdbTrailingSkip: ctdbTrailingSkip
            ),
            onAudio: onAudio,
            progress: progress
        )

        if case .secure(let maxRetries, let agreeingPasses) = config.mode, !useC2 {
            return try await twoPassCompareRip(
                context, maxRetries: maxRetries, agreeingPasses: agreeingPasses
            )
        }
        return try await singlePassRip(context)
    }

    private struct TrackContext {
        let track: TOCTrack
        let sectors: Range<Int>
        let trackByteStart: Int
        let wavURL: URL
        var checksums: ChecksumAccumulator
        let onAudio: (@Sendable (Data) -> Void)?
        let progress: @Sendable (RipProgress) -> Void

        /// Corrected byte window of one output sector.
        func window(ofOutputSector index: Int) -> Range<Int> {
            (trackByteStart + index * 2352) ..< (trackByteStart + (index + 1) * 2352)
        }
    }

    // MARK: Burst and C2 single-pass path

    private func singlePassRip(_ context: TrackContext) async throws -> RippedTrack {
        var context = context
        let totalSectors = context.sectors.count
        let writer = try WAVWriter(url: context.wavURL, expectedDataBytes: totalSectors * 2352)
        var rereads = 0
        var unrecoverable: [Int] = []

        var outputSector = 0
        while outputSector < totalSectors {
            try Task.checkCancellation()
            let chunk = min(config.chunkSectors, totalSectors - outputSector)
            let byteRange = (context.trackByteStart + outputSector * Self.bytesPerSector)
                ..< (context.trackByteStart + (outputSector + chunk) * Self.bytesPerSector)

            let result = try await readChunk(for: byteRange)
            rereads += result.rereads
            unrecoverable.append(contentsOf: result.unrecoverableSectors)

            try writer.append(result.audio)
            context.checksums.update(result.audio)
            context.onAudio?(result.audio)

            outputSector += chunk
            context.progress(RipProgress(
                trackNumber: context.track.number,
                sectorsCompleted: outputSector,
                totalSectors: totalSectors,
                rereads: rereads
            ))
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

    /// Pass 1 writes the track; a cache-bust separates the passes; pass 2
    /// re-reads everything and compares per-sector CRCs. Sectors that differ
    /// between passes are settled by voting with cache-busted re-reads and
    /// patched into the WAV. Checksums are computed from the final file.
    private func twoPassCompareRip(
        _ context: TrackContext, maxRetries: Int, agreeingPasses: Int
    ) async throws -> RippedTrack {
        var context = context
        let totalSectors = context.sectors.count
        let progressTotal = totalSectors * 2
        var rereads = 1 // count the verification pass like before
        var unrecoverable: [Int] = []

        // Pass 1: write the WAV, remember a CRC per output sector.
        let writer = try WAVWriter(url: context.wavURL, expectedDataBytes: totalSectors * 2352)
        var sectorCRCs = [UInt32]()
        sectorCRCs.reserveCapacity(totalSectors)

        var outputSector = 0
        while outputSector < totalSectors {
            try Task.checkCancellation()
            let chunk = min(config.chunkSectors, totalSectors - outputSector)
            let byteRange = (context.trackByteStart + outputSector * Self.bytesPerSector)
                ..< (context.trackByteStart + (outputSector + chunk) * Self.bytesPerSector)
            let result = try await readChunk(for: byteRange)
            try writer.append(result.audio)
            for s in 0 ..< chunk {
                sectorCRCs.append(CRC32.checksum(result.audio.subdata(
                    in: result.audio.startIndex + s * 2352 ..< result.audio.startIndex + (s + 1) * 2352
                )))
            }
            outputSector += chunk
            context.progress(RipProgress(
                trackNumber: context.track.number,
                sectorsCompleted: outputSector,
                totalSectors: progressTotal,
                rereads: 0
            ))
        }
        try writer.finish()

        // Force the second pass to the medium even for tracks smaller than
        // the drive cache.
        await bustCache(awayFrom: context.sectors.lowerBound)

        // Pass 2: re-read, compare, settle and patch mismatches.
        guard let patcher = try? FileHandle(forWritingTo: context.wavURL) else {
            throw RipError.cancelled
        }
        defer { try? patcher.close() }

        outputSector = 0
        while outputSector < totalSectors {
            try Task.checkCancellation()
            let chunk = min(config.chunkSectors, totalSectors - outputSector)
            let byteRange = (context.trackByteStart + outputSector * Self.bytesPerSector)
                ..< (context.trackByteStart + (outputSector + chunk) * Self.bytesPerSector)
            let result = try await readChunk(for: byteRange)

            for s in 0 ..< chunk {
                let secondBytes = result.audio.subdata(
                    in: result.audio.startIndex + s * 2352 ..< result.audio.startIndex + (s + 1) * 2352
                )
                let index = outputSector + s
                guard CRC32.checksum(secondBytes) != sectorCRCs[index] else { continue }

                let settled = try await settleWindow(
                    context.window(ofOutputSector: index),
                    initialCandidate: secondBytes,
                    maxRetries: maxRetries,
                    agreeingPasses: agreeingPasses
                )
                rereads += settled.rereads
                if !settled.recovered {
                    unrecoverable.append(context.sectors.lowerBound + index)
                }
                try patcher.seek(toOffset: UInt64(44 + index * 2352))
                try patcher.write(contentsOf: settled.audio)
            }

            outputSector += chunk
            context.progress(RipProgress(
                trackNumber: context.track.number,
                sectorsCompleted: totalSectors + outputSector,
                totalSectors: progressTotal,
                rereads: rereads - 1
            ))
        }
        try patcher.close()

        // Checksums over the final, patched audio.
        let reader = try FileHandle(forReadingFrom: context.wavURL)
        defer { try? reader.close() }
        try reader.seek(toOffset: 44)
        while let data = try reader.read(upToCount: 4 << 20), !data.isEmpty {
            context.checksums.update(data)
            context.onAudio?(data)
        }

        return RippedTrack(
            trackNumber: context.track.number,
            wavURL: context.wavURL,
            checksums: context.checksums.finalize(),
            rereads: rereads,
            unrecoverableSectors: unrecoverable.sorted(),
            usedC2: false
        )
    }

    // MARK: Chunk reads

    private struct ChunkResult {
        var audio: Data
        var rereads: Int
        var unrecoverableSectors: [Int]
    }

    /// Returns the bytes of the virtual disc byte stream for `byteRange`,
    /// zero-filled where the range falls outside the readable sector bounds.
    /// In C2 mode, flagged sectors are settled inline.
    private func readChunk(for byteRange: Range<Int>) async throws -> ChunkResult {
        let bps = Self.bytesPerSector
        let firstSector = byteRange.lowerBound.flooredDivision(by: bps)
        let lastSector = (byteRange.upperBound + bps - 1).flooredDivision(by: bps)
        let span = firstSector ..< lastSector
        let clamped = span.clamped(to: readableSectors)

        var raw = Data(count: span.count * bps)
        var rereads = 0
        var unrecoverable: [Int] = []

        if !clamped.isEmpty {
            let read: ChunkResult
            if case .secure(let maxRetries, let agreeingPasses) = config.mode, useC2 {
                read = try await readWithC2(
                    sectors: clamped, maxRetries: maxRetries, agreeingPasses: agreeingPasses
                )
            } else {
                let buffer = try await device.readSectors(clamped, areas: .user)
                read = ChunkResult(audio: buffer.allAudio(), rereads: 0, unrecoverableSectors: [])
            }
            rereads = read.rereads
            unrecoverable = read.unrecoverableSectors
            let dest = (clamped.lowerBound - firstSector) * bps
            raw.replaceSubrange(dest ..< dest + read.audio.count, with: read.audio)
        }

        let sliceStart = byteRange.lowerBound - firstSector * bps
        return ChunkResult(
            audio: raw.subdata(in: sliceStart ..< sliceStart + byteRange.count),
            rereads: rereads,
            unrecoverableSectors: unrecoverable
        )
    }

    private func readWithC2(
        sectors: Range<Int>, maxRetries: Int, agreeingPasses: Int
    ) async throws -> ChunkResult {
        let buffer = try await device.readSectors(sectors, areas: [.user, .errorFlags])
        var audio = Data(capacity: sectors.count * Self.bytesPerSector)
        var rereads = 0
        var unrecoverable: [Int] = []

        for index in 0 ..< sectors.count {
            if buffer.hasC2Error(sector: index) {
                let lba = sectors.lowerBound + index
                let settled = try await settleSector(
                    lba: lba, maxRetries: maxRetries, agreeingPasses: agreeingPasses
                )
                rereads += settled.rereads
                if !settled.recovered { unrecoverable.append(lba) }
                audio.append(settled.audio)
            } else {
                audio.append(buffer.audio(sector: index))
            }
        }
        return ChunkResult(audio: audio, rereads: rereads, unrecoverableSectors: unrecoverable)
    }

    // MARK: Settling

    private struct SettledData {
        var audio: Data
        var rereads: Int
        var recovered: Bool
    }

    /// Re-reads a single device sector (C2 path) until `agreeingPasses`
    /// clean byte-identical reads agree. Every read is preceded by a
    /// cache-busting jump so agreement reflects the medium, not the cache.
    private func settleSector(
        lba: Int, maxRetries: Int, agreeingPasses: Int
    ) async throws -> SettledData {
        var counts: [Data: Int] = [:]
        var rereads = 0

        while rereads < maxRetries {
            try Task.checkCancellation()
            await bustCache(awayFrom: lba)
            let buffer = try await device.readSectors(lba ..< lba + 1, areas: [.user, .errorFlags])
            rereads += 1
            guard !buffer.hasC2Error(sector: 0) else { continue }
            let audio = buffer.audio(sector: 0)
            let count = (counts[audio] ?? 0) + 1
            counts[audio] = count
            if count >= agreeingPasses {
                return SettledData(audio: audio, rereads: rereads, recovered: true)
            }
        }

        let best = counts.max { $0.value < $1.value }?.key ?? Data(count: Self.bytesPerSector)
        return SettledData(audio: best, rereads: rereads, recovered: false)
    }

    /// Settles one corrected output-sector window (compare path): re-reads
    /// its input span with cache busting until `agreeingPasses` identical
    /// windows agree.
    private func settleWindow(
        _ byteRange: Range<Int>,
        initialCandidate: Data?,
        maxRetries: Int,
        agreeingPasses: Int
    ) async throws -> SettledData {
        var counts: [Data: Int] = [:]
        if let initialCandidate { counts[initialCandidate] = 1 }
        var rereads = 0

        let bps = Self.bytesPerSector
        let firstSector = byteRange.lowerBound.flooredDivision(by: bps)

        while rereads < maxRetries {
            try Task.checkCancellation()
            await bustCache(awayFrom: max(firstSector, readableSectors.lowerBound))

            let lastSector = (byteRange.upperBound + bps - 1).flooredDivision(by: bps)
            let clamped = (firstSector ..< lastSector).clamped(to: readableSectors)
            var raw = Data(count: (lastSector - firstSector) * bps)
            if !clamped.isEmpty {
                guard let buffer = try? await device.readSectors(clamped, areas: .user) else {
                    rereads += 1
                    continue
                }
                let dest = (clamped.lowerBound - firstSector) * bps
                let audio = buffer.allAudio()
                raw.replaceSubrange(dest ..< dest + audio.count, with: audio)
            }
            rereads += 1

            let sliceStart = byteRange.lowerBound - firstSector * bps
            let window = raw.subdata(in: sliceStart ..< sliceStart + byteRange.count)
            let count = (counts[window] ?? 0) + 1
            counts[window] = count
            if count >= agreeingPasses {
                return SettledData(audio: window, rereads: rereads, recovered: true)
            }
        }

        let best = counts.max { $0.value < $1.value }?.key ?? Data(count: byteRange.count)
        return SettledData(audio: best, rereads: rereads, recovered: false)
    }

    /// Forces the drive to evict its read cache by touching a sector on the
    /// far side of the audio area (cdparanoia-style backseek flush).
    private func bustCache(awayFrom lba: Int) async {
        let area = readableSectors
        guard area.count > 1 else { return }
        let half = area.count / 2
        let target = area.lowerBound + ((lba - area.lowerBound) + half) % area.count
        _ = try? await device.readSectors(target ..< target + 1, areas: .user)
    }
}

extension Int {
    /// Floored division (rounds toward negative infinity), needed because
    /// negative-offset byte positions must map to the preceding sector.
    func flooredDivision(by divisor: Int) -> Int {
        let q = self / divisor
        return (self % divisor != 0 && (self < 0) != (divisor < 0)) ? q - 1 : q
    }
}
