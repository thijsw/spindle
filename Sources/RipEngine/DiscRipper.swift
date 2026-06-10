import DiscDrive
import Foundation

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

    public func rip(
        toc: TOC,
        to stagingDirectory: URL,
        progress: @Sendable @escaping (RipProgress) -> Void = { _ in }
    ) async throws -> [RippedTrack] {
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
                to: wavURL,
                progress: progress
            )
            results.append(ripped)
        }
        return results
    }
}
