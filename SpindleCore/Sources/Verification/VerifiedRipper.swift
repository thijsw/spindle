import DiscDrive
import Foundation
import RipEngine

/// Verification-first disc ripping (the dbpoweramp model):
///
/// 1. Rip the whole disc in fast burst mode while streaming checksums.
/// 2. Check every track against the checksum database. Independent agreement
///    across other people's drives is stronger evidence of correctness than
///    any amount of single-drive re-reading.
/// 3. Only the tracks the database can't confirm are re-ripped with the
///    secure engine (C2-triaged or two-pass compare with cache busting), and
///    the result is verified again.
///
/// Discs absent from the database fall back to a full secure rip.
public struct VerifiedRipper: Sendable {
    public struct Outcome: Sendable {
        public var tracks: [RippedTrack]
        public var verification: VerificationResult?
        /// Track numbers that needed a secure re-rip after the fast pass.
        public var reRippedTracks: [Int]
        /// Human-readable description of which strategy resolved the rip.
        public var strategy: String
        /// True when the drive's C2 reporting was caught lying — remember
        /// per drive and disable C2 for it in future rips.
        public var c2Unreliable: Bool
    }

    private let device: any CDDeviceIO
    private let configuration: RipConfiguration
    private let verifier: (any RipVerifier)?

    public init(device: any CDDeviceIO, configuration: RipConfiguration, verifier: (any RipVerifier)?) {
        self.device = device
        self.configuration = configuration
        self.verifier = verifier
    }

    public func rip(
        toc: TOC,
        to stagingDirectory: URL,
        progress: @Sendable @escaping (RipProgress) -> Void = { _ in }
    ) async throws -> Outcome {
        let secureRequested: Bool = if case .secure = configuration.mode { true } else { false }
        // One damage chart for the whole operation: scratches mapped during
        // the burst pass are never re-probed by the secure re-rip.
        let damage = TrackRipper.DamageMap()

        // Without a verifier, a fast first pass proves nothing — go straight
        // to the secure engine instead of ripping everything twice.
        if secureRequested, verifier == nil {
            let secure = try await DiscRipper(device: device, config: configuration, damage: damage)
                .ripDisc(toc: toc, to: stagingDirectory, progress: progress)
            return Outcome(
                tracks: secure.tracks,
                verification: nil,
                reRippedTracks: [],
                strategy: "Secure rip (no verification database available)",
                c2Unreliable: secure.c2Distrusted
            )
        }

        // Pass 1: burst, regardless of mode — the database may spare us
        // the slow machinery entirely.
        var burstConfiguration = configuration
        burstConfiguration.mode = .burst
        let firstPass = try await DiscRipper(device: device, config: burstConfiguration, damage: damage)
            .ripDisc(toc: toc, to: stagingDirectory, progress: progress)

        var verification = await verify(
            toc: toc, tracks: firstPass.tracks, discCRC: firstPass.ctdbDiscCRC32
        )

        guard secureRequested else {
            return Outcome(
                tracks: firstPass.tracks,
                verification: verification,
                reRippedTracks: [],
                strategy: "Fast rip" + (verification.map { " — \($0.summary)" } ?? ""),
                c2Unreliable: firstPass.c2Distrusted
            )
        }

        // Which tracks does the database vouch for?
        let unverified: [Int]
        if let verification, !verification.entries.isEmpty {
            unverified = verification.trackVerdicts
                .filter { if case .accuratelyRipped = $0.value { false } else { true } }
                .map(\.key)
                .sorted()
        } else {
            // Unknown disc (or offline): nothing is vouched for.
            unverified = toc.audioTracks.map(\.number)
        }

        if unverified.isEmpty, let verification {
            return Outcome(
                tracks: firstPass.tracks,
                verification: verification,
                reRippedTracks: [],
                strategy: "Verified against CTDB in the fast pass — \(verification.summary)",
                c2Unreliable: firstPass.c2Distrusted
            )
        }

        // Pass 2: secure re-rip of only the unconfirmed tracks.
        let secondPass = try await DiscRipper(device: device, config: configuration, damage: damage)
            .ripDisc(toc: toc, only: Set(unverified), to: stagingDirectory, progress: progress)

        var merged = firstPass.tracks.filter { !unverified.contains($0.trackNumber) }
        merged.append(contentsOf: secondPass.tracks)
        merged.sort { $0.trackNumber < $1.trackNumber }

        // Re-verify the final state (disc CRC is stale after partial re-rips).
        verification = await verify(toc: toc, tracks: merged, discCRC: nil) ?? verification

        let strategy: String
        if let verification, !verification.entries.isEmpty {
            strategy = "Secure re-rip of \(unverified.count) of \(toc.audioTracks.count) tracks — \(verification.summary)"
        } else {
            strategy = "Full secure rip (disc not in CTDB — no database verification possible)"
        }
        return Outcome(
            tracks: merged,
            verification: verification,
            reRippedTracks: unverified,
            strategy: strategy,
            c2Unreliable: firstPass.c2Distrusted || secondPass.c2Distrusted
        )
    }

    private func verify(toc: TOC, tracks: [RippedTrack], discCRC: UInt32?) async -> VerificationResult? {
        guard let verifier else { return nil }
        let checksums = tracks.reduce(into: [Int: TrackChecksums]()) {
            $0[$1.trackNumber] = $1.checksums
        }
        return try? await verifier.verify(toc: toc, trackChecksums: checksums, ctdbDiscCRC32: discCRC)
    }
}
