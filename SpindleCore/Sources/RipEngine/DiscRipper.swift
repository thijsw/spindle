import DiscDrive
import Foundation

/// Accumulates the disc-spanning CTDB CRC as tracks stream by, in rip order.
final class DiscCRCBox: @unchecked Sendable {
    private var crc: RangeGatedCRC32
    private let lock = NSLock()

    init(coveredBytes: Range<Int>, startBytePosition: Int) {
        // The gate's position counter starts at 0; shift the window so byte 0
        // of the stream corresponds to the first audio track's start.
        crc = RangeGatedCRC32(
            coveredBytes: (coveredBytes.lowerBound - startBytePosition)
                ..< (coveredBytes.upperBound - startBytePosition)
        )
    }

    func update(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        crc.update(data)
    }

    var value: UInt32 {
        lock.lock()
        defer { lock.unlock() }
        return crc.value
    }
}

/// Rips all audio tracks of a disc into a staging directory.
public struct DiscRipper: Sendable {
    public let device: any CDDeviceIO
    public let config: RipConfiguration

    public init(device: any CDDeviceIO, config: RipConfiguration) {
        self.device = device
        self.config = config
    }

    /// Probes whether the drive returns *usable* C2 error pointers.
    ///
    /// Merely succeeding at the ioctl is not enough: some drives (the Apple
    /// SuperDrive among them) accept the request but fill the entire
    /// transfer with garbage. C2 is trusted only if the audio portion of a
    /// C2 read is byte-identical to a plain read of the same sectors and
    /// the error flags aren't lighting up wall-to-wall on a readable area.
    public func probeC2(firstAudioLBA: Int) async -> Bool {
        let count = 32
        let range = firstAudioLBA ..< firstAudioLBA + count
        guard let plain = try? await device.readSectors(range, areas: .user),
              let withC2 = try? await device.readSectors(range, areas: [.user, .errorFlags])
        else { return false }

        guard withC2.allAudio() == plain.allAudio() else { return false }

        let flagged = (0 ..< count).count { withC2.hasC2Error(sector: $0) }
        return flagged < count / 4
    }

    public struct DiscRipResult: Sendable {
        public let tracks: [RippedTrack]
        /// CTDB whole-disc CRC32 (skip-gated), for matching entry `crc32`.
        /// Only meaningful when the whole disc was ripped in one go.
        public let ctdbDiscCRC32: UInt32
        public let isCompleteDisc: Bool
        public let usedC2: Bool
        /// True when the drive's C2 was caught lying during this rip;
        /// remember this per drive and set `allowC2 = false` next time.
        public let c2Distrusted: Bool
    }

    public func rip(
        toc: TOC,
        to stagingDirectory: URL,
        progress: @Sendable @escaping (RipProgress) -> Void = { _ in }
    ) async throws -> [RippedTrack] {
        try await ripDisc(toc: toc, to: stagingDirectory, progress: progress).tracks
    }

    /// Rips the disc's audio tracks; `only` restricts to a subset (used for
    /// secure re-rips of tracks that failed verification).
    public func ripDisc(
        toc: TOC,
        only: Set<Int>? = nil,
        to stagingDirectory: URL,
        progress: @Sendable @escaping (RipProgress) -> Void = { _ in }
    ) async throws -> DiscRipResult {
        let audioTracks = toc.audioTracks
        guard !audioTracks.isEmpty else { throw RipError.noAudioTracks }

        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        if let speed = config.speedKBps {
            try? await device.setSpeed(speed) // best effort; drives may refuse
        }

        var needsC2 = false
        if case .secure = config.mode, config.allowC2 {
            needsC2 = await probeC2(firstAudioLBA: audioTracks[0].startLBA)
        }

        // The readable audio area ends at the lead-out of the session that
        // contains the audio (relevant for Enhanced CDs).
        let audioSession = audioTracks[0].session
        let audioEnd = toc.sessionLeadOuts[audioSession] ?? toc.leadOutLBA

        // Probe the largest transfer the drive accepts: halve the chunk size
        // until a read succeeds (some drives/bridges cap request sizes).
        var tunedConfig = config
        let probeAreas: SectorAreas = needsC2 ? [.user, .errorFlags] : .user
        while tunedConfig.chunkSectors > 25 {
            let start = audioTracks[0].startLBA
            let range = start ..< min(start + tunedConfig.chunkSectors, audioEnd)
            if (try? await device.readSectors(range, areas: probeAreas)) != nil { break }
            tunedConfig.chunkSectors /= 2
        }

        // CTDB skip windows: 2940 samples (5 sectors) into the first track,
        // and 2940 + (disc-length remainder mod 2940) before the lead-out.
        let totalSamples = audioEnd * 588
        let ctdbPrefix = 2940
        let ctdbSuffix = 2940 + totalSamples % 2940
        let firstAudioStart = audioTracks[0].startLBA * 588
        let discCRC = DiscCRCBox(
            coveredBytes: (firstAudioStart + ctdbPrefix) * 4 ..< (totalSamples - ctdbSuffix) * 4,
            startBytePosition: firstAudioStart * 4
        )

        let selected = audioTracks.filter { only?.contains($0.number) ?? true }
        let isCompleteDisc = selected.count == audioTracks.count
        let tap: @Sendable (Data) -> Void = { discCRC.update($0) }
        let audioTap: (@Sendable (Data) -> Void)? = isCompleteDisc ? tap : nil

        var results: [RippedTrack] = []
        var c2Distrusted = false
        for track in selected {
            let wavURL = stagingDirectory.appendingPathComponent(
                String(format: "track%02d.wav", track.number)
            )
            let ripper = TrackRipper(
                device: device,
                config: tunedConfig,
                readableSectors: 0 ..< audioEnd,
                useC2: needsC2
            )
            let ripped = try await ripper.rip(
                track: track,
                toc: toc,
                isFirstAudio: track.number == audioTracks.first?.number,
                isLastAudio: track.number == audioTracks.last?.number,
                ctdbLeadingSkip: track.number == audioTracks.first?.number ? ctdbPrefix : 0,
                ctdbTrailingSkip: track.number == audioTracks.last?.number ? ctdbSuffix : 0,
                to: wavURL,
                onAudio: audioTap,
                progress: progress
            )
            results.append(ripped)
            if ripped.c2Distrusted {
                // The drive's C2 lied: stop using it for the rest of the disc.
                needsC2 = false
                c2Distrusted = true
            }
        }
        return DiscRipResult(
            tracks: results,
            ctdbDiscCRC32: discCRC.value,
            isCompleteDisc: isCompleteDisc,
            usedC2: needsC2,
            c2Distrusted: c2Distrusted
        )
    }
}
