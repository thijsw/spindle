import DiscDrive
import Foundation

/// Rips all audio tracks of a disc into a staging directory.
public struct DiscRipper: Sendable {
    public let device: any CDDeviceIO
    public let configuration: RipConfiguration
    /// Shared chart of unreadable runs; pass the same instance to related
    /// rips (e.g. verify-first burst + secure re-rip) so damage is probed
    /// exactly once per disc.
    public let damage: DamageMap

    public init(
        device: any CDDeviceIO,
        configuration: RipConfiguration,
        damage: DamageMap = DamageMap()
    ) {
        self.device = device
        self.configuration = configuration
        self.damage = damage
    }

    public struct DiscRipResult: Sendable {
        public let tracks: [RippedTrack]
        /// CTDB whole-disc CRC32 (skip-gated), for matching entry `crc32`.
        /// Only meaningful when the whole disc was ripped in one go.
        public let ctdbDiscCRC32: UInt32
        public let isCompleteDisc: Bool
        /// Whether C2 was still trusted when the rip ended.
        public let usedC2: Bool
        /// True when the drive's C2 was caught lying during this rip;
        /// remember this per drive and set `allowC2 = false` next time.
        public let c2Unreliable: Bool
        /// Tracks abandoned because they exceeded the per-track time budget.
        public let failedTracks: [Int]
        /// The request size the drive accepted; pass it to a follow-up rip
        /// (`configuration.chunkSectors`) to skip re-probing.
        public let tunedChunkSectors: Int
    }

    /// Probes whether the drive returns *usable* C2 error pointers.
    ///
    /// Merely succeeding at the ioctl is not enough: some drives (the Apple
    /// SuperDrive among them) accept the request but fill the entire
    /// transfer with garbage. C2 is trusted only if the audio portion of a
    /// C2 read is byte-identical to a plain read of the same sectors and
    /// the error flags aren't lighting up wall-to-wall on a readable area.
    func probeC2(firstAudioLBA: Int) async -> Bool {
        let count = 32
        let range = firstAudioLBA ..< firstAudioLBA + count
        guard let plain = try? await device.readSectors(range, areas: .user),
              let withC2 = try? await device.readSectors(range, areas: [.user, .errorFlags])
        else { return false }

        guard withC2.allAudio() == plain.allAudio() else { return false }
        return withC2.c2FlaggedSectors().count < count / 4
    }

    /// Probes the largest transfer the drive accepts: halves the chunk size
    /// until a read succeeds (some drives/bridges cap request sizes).
    private func tunedChunkSectors(from start: Int, audioEnd: Int, areas: SectorAreas) async -> Int {
        var chunk = configuration.chunkSectors
        while chunk > 25 {
            let range = start ..< min(start + chunk, audioEnd)
            if (try? await device.readSectors(range, areas: areas)) != nil { break }
            chunk /= 2
        }
        return chunk
    }

    /// Rips the disc's audio tracks; `only` restricts to a subset (used for
    /// secure re-rips of tracks that failed verification).
    public func rip(
        toc: TOC,
        only: Set<Int>? = nil,
        to stagingDirectory: URL,
        progress: @Sendable @escaping (RipProgress) -> Void = { _ in }
    ) async throws -> DiscRipResult {
        let audioTracks = toc.audioTracks
        guard let firstAudio = audioTracks.first else { throw RipError.noAudioTracks }

        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        if let speed = configuration.speedKBps {
            try? await device.setSpeed(speed) // best effort; drives may refuse
        }

        var needsC2 = false
        if case .secure = configuration.mode, configuration.allowC2 {
            needsC2 = await probeC2(firstAudioLBA: firstAudio.startLBA)
        }

        // The readable audio area ends at the lead-out of the session that
        // contains the audio (relevant for Enhanced CDs).
        let audioEnd = toc.audioLeadOutLBA
        var tuned = configuration
        tuned.chunkSectors = await tunedChunkSectors(
            from: firstAudio.startLBA, audioEnd: audioEnd, areas: needsC2 ? [.user, .errorFlags] : .user
        )

        // The disc-spanning CTDB CRC accumulates as tracks stream by, in rip
        // order; it only means something when every track is ripped.
        let selected = audioTracks.filter { only?.contains($0.number) ?? true }
        let isCompleteDisc = selected.count == audioTracks.count
        var discCRC = CTDBWindow.discWindow(for: toc).map { window in
            RangeGatedCRC32(
                coveredBytes: (window.lowerBound - firstAudio.startLBA * SectorAreas.samplesPerSector) * 4
                    ..< (window.upperBound - firstAudio.startLBA * SectorAreas.samplesPerSector) * 4
            )
        }
        let audioTap: ((Data) -> Void)? = isCompleteDisc ? { discCRC?.update($0) } : nil

        var results: [RippedTrack] = []
        var c2Unreliable = false
        var failedTracks: [Int] = []
        for track in selected {
            let wavURL = stagingDirectory.appendingPathComponent(String(format: "track%02d.wav", track.number))
            let ripper = TrackRipper(
                device: device,
                configuration: tuned,
                readableSectors: 0 ..< audioEnd,
                useC2: needsC2,
                damage: damage
            )
            do {
                let ripped = try await ripper.rip(
                    track: track,
                    toc: toc,
                    position: TrackPosition(of: track, in: toc),
                    to: wavURL,
                    onAudio: audioTap,
                    progress: progress
                )
                results.append(ripped)
                if ripped.c2Unreliable {
                    // The drive's C2 lied: stop using it for the rest of the disc.
                    needsC2 = false
                    c2Unreliable = true
                }
            } catch RipError.trackTimeLimitExceeded {
                // Give up on this track, keep the disc moving: the next
                // track usually starts on readable ground.
                failedTracks.append(track.number)
                try? FileManager.default.removeItem(at: wavURL)
            }
        }
        return DiscRipResult(
            tracks: results,
            ctdbDiscCRC32: discCRC?.value ?? 0,
            isCompleteDisc: isCompleteDisc && failedTracks.isEmpty,
            usedC2: needsC2,
            c2Unreliable: c2Unreliable,
            failedTracks: failedTracks,
            tunedChunkSectors: tuned.chunkSectors
        )
    }
}
