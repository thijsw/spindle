import DiscDrive
import Foundation

/// Rips one track: reads sectors (securely if configured), applies sample
/// offset correction with zero-fill at disc edges, streams audio into a
/// staging WAV, and computes checksums on the corrected stream.
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
        to wavURL: URL,
        progress: @Sendable @escaping (RipProgress) -> Void
    ) async throws -> RippedTrack {
        let sectors = toc.sectorRange(of: track)
        let totalSectors = sectors.count
        let writer = try WAVWriter(url: wavURL)
        var checksums = ChecksumAccumulator(
            totalSamples: totalSectors * 588,
            isFirstTrack: isFirstAudio,
            isLastTrack: isLastAudio
        )
        var rereads = 0
        var unrecoverable: [Int] = []

        // The corrected stream for the track is the virtual disc byte stream
        // (zero outside the readable area) shifted by the drive offset.
        let byteShift = config.sampleOffset * 4
        let trackByteStart = sectors.lowerBound * Self.bytesPerSector + byteShift

        var outputSector = 0
        while outputSector < totalSectors {
            try Task.checkCancellation()
            let chunk = min(config.chunkSectors, totalSectors - outputSector)
            let byteRange = (trackByteStart + outputSector * Self.bytesPerSector)
                ..< (trackByteStart + (outputSector + chunk) * Self.bytesPerSector)

            let result = try await correctedBytes(for: byteRange)
            rereads += result.rereads
            unrecoverable.append(contentsOf: result.unrecoverableSectors)

            try writer.append(result.audio)
            checksums.update(result.audio)

            outputSector += chunk
            progress(RipProgress(
                trackNumber: track.number,
                sectorsCompleted: outputSector,
                totalSectors: totalSectors,
                rereads: rereads
            ))
        }

        try writer.finish()
        return RippedTrack(
            trackNumber: track.number,
            wavURL: wavURL,
            checksums: checksums.finalize(),
            rereads: rereads,
            unrecoverableSectors: unrecoverable.sorted(),
            usedC2: useC2
        )
    }

    private struct ChunkResult {
        var audio: Data
        var rereads: Int
        var unrecoverableSectors: [Int]
    }

    /// Returns the bytes of the virtual disc byte stream for `byteRange`,
    /// zero-filled where the range falls outside the readable sector bounds.
    private func correctedBytes(for byteRange: Range<Int>) async throws -> ChunkResult {
        let bps = Self.bytesPerSector
        let firstSector = byteRange.lowerBound.flooredDivision(by: bps)
        let lastSector = (byteRange.upperBound + bps - 1).flooredDivision(by: bps)
        let span = firstSector ..< lastSector
        let clamped = span.clamped(to: readableSectors)

        var raw = Data(count: span.count * bps)
        var rereads = 0
        var unrecoverable: [Int] = []

        if !clamped.isEmpty {
            let read = try await readReliably(sectors: clamped)
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

    /// Reads a sector range according to the configured mode, returning plain
    /// audio bytes (count × 2352).
    private func readReliably(sectors: Range<Int>) async throws -> ChunkResult {
        switch config.mode {
        case .burst:
            let buffer = try await device.readSectors(sectors, areas: .user)
            return ChunkResult(audio: buffer.allAudio(), rereads: 0, unrecoverableSectors: [])

        case .secure(let maxRetries, let agreeingPasses):
            if useC2 {
                return try await secureReadWithC2(
                    sectors: sectors, maxRetries: maxRetries, agreeingPasses: agreeingPasses
                )
            } else {
                return try await secureReadByComparison(
                    sectors: sectors, maxRetries: maxRetries, agreeingPasses: agreeingPasses
                )
            }
        }
    }

    private func secureReadWithC2(
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
                    lba: lba,
                    initial: nil, // the C2-flagged read doesn't count as a clean pass
                    maxRetries: maxRetries,
                    agreeingPasses: agreeingPasses
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

    private func secureReadByComparison(
        sectors: Range<Int>, maxRetries: Int, agreeingPasses: Int
    ) async throws -> ChunkResult {
        // Without C2 information, read the chunk twice and re-read sectors
        // whose two passes disagree.
        let first = try await device.readSectors(sectors, areas: .user)
        let second = try await device.readSectors(sectors, areas: .user)
        var audio = Data(capacity: sectors.count * Self.bytesPerSector)
        var rereads = 1 // the verification pass
        var unrecoverable: [Int] = []

        for index in 0 ..< sectors.count {
            let a = first.audio(sector: index)
            if a == second.audio(sector: index) {
                audio.append(a)
            } else {
                let lba = sectors.lowerBound + index
                let settled = try await settleSector(
                    lba: lba, initial: a, maxRetries: maxRetries, agreeingPasses: agreeingPasses
                )
                rereads += settled.rereads
                if !settled.recovered { unrecoverable.append(lba) }
                audio.append(settled.audio)
            }
        }
        return ChunkResult(audio: audio, rereads: rereads, unrecoverableSectors: unrecoverable)
    }

    private struct SettledSector {
        var audio: Data
        var rereads: Int
        var recovered: Bool
    }

    /// Re-reads a single sector until `agreeingPasses` byte-identical clean
    /// reads agree, or retries are exhausted (then: most frequent read wins).
    private func settleSector(
        lba: Int, initial: Data?, maxRetries: Int, agreeingPasses: Int
    ) async throws -> SettledSector {
        var counts: [Data: Int] = [:]
        if let initial { counts[initial] = 1 }
        var rereads = 0
        let areas: SectorAreas = useC2 ? [.user, .errorFlags] : .user

        while rereads < maxRetries {
            try Task.checkCancellation()
            let buffer = try await device.readSectors(lba ..< lba + 1, areas: areas)
            rereads += 1
            guard !buffer.hasC2Error(sector: 0) else { continue }
            let audio = buffer.audio(sector: 0)
            let count = (counts[audio] ?? 0) + 1
            counts[audio] = count
            if count >= agreeingPasses {
                return SettledSector(audio: audio, rereads: rereads, recovered: true)
            }
        }

        let best = counts.max { $0.value < $1.value }?.key
            ?? Data(count: Self.bytesPerSector)
        return SettledSector(audio: best, rereads: rereads, recovered: false)
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
