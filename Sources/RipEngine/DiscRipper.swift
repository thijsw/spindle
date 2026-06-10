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

    /// Probes whether the drive returns C2 error pointers. Some drives reject
    /// the request outright; those fall back to compare-based secure reads.
    public func probeC2(firstAudioLBA: Int) async -> Bool {
        do {
            _ = try await device.readSectors(firstAudioLBA ..< firstAudioLBA + 1, areas: [.user, .errorFlags])
            return true
        } catch {
            return false
        }
    }

    public struct DiscRipResult: Sendable {
        public let tracks: [RippedTrack]
        /// CTDB whole-disc CRC32 (skip-gated), for matching entry `crc32`.
        public let ctdbDiscCRC32: UInt32
        public let usedC2: Bool
    }

    public func rip(
        toc: TOC,
        to stagingDirectory: URL,
        progress: @Sendable @escaping (RipProgress) -> Void = { _ in }
    ) async throws -> [RippedTrack] {
        try await ripDisc(toc: toc, to: stagingDirectory, progress: progress).tracks
    }

    public func ripDisc(
        toc: TOC,
        to stagingDirectory: URL,
        progress: @Sendable @escaping (RipProgress) -> Void = { _ in }
    ) async throws -> DiscRipResult {
        let audioTracks = toc.audioTracks
        guard !audioTracks.isEmpty else { throw RipError.noAudioTracks }

        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        if let speed = config.speedKBps {
            try? await device.setSpeed(speed) // best effort; drives may refuse
        }

        let needsC2: Bool
        if case .secure = config.mode {
            needsC2 = await probeC2(firstAudioLBA: audioTracks[0].startLBA)
        } else {
            needsC2 = false
        }

        // The readable audio area ends at the lead-out of the session that
        // contains the audio (relevant for Enhanced CDs).
        let audioSession = audioTracks[0].session
        let audioEnd = toc.sessionLeadOuts[audioSession] ?? toc.leadOutLBA

        let ripper = TrackRipper(
            device: device,
            config: config,
            readableSectors: 0 ..< audioEnd,
            useC2: needsC2
        )

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

        var results: [RippedTrack] = []
        for track in audioTracks {
            let wavURL = stagingDirectory.appendingPathComponent(
                String(format: "track%02d.wav", track.number)
            )
            let ripped = try await ripper.rip(
                track: track,
                toc: toc,
                isFirstAudio: track.number == audioTracks.first?.number,
                isLastAudio: track.number == audioTracks.last?.number,
                ctdbLeadingSkip: track.number == audioTracks.first?.number ? ctdbPrefix : 0,
                ctdbTrailingSkip: track.number == audioTracks.last?.number ? ctdbSuffix : 0,
                to: wavURL,
                onAudio: { discCRC.update($0) },
                progress: progress
            )
            results.append(ripped)
        }
        return DiscRipResult(tracks: results, ctdbDiscCRC32: discCRC.value, usedC2: needsC2)
    }
}
