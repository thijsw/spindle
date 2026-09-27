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
    /// Which path produced the final audio.
    public enum Strategy: Sendable, Equatable {
        /// Secure rip only (no verification database was available).
        case secureOnly
        /// Fast rip, as requested.
        case fast
        /// Secure was requested, but the fast pass verified or read clean.
        case fastTrusted
        /// The fast pass left tracks with read errors; those were re-ripped.
        case secureReRip(trackCount: Int)
    }

    public struct Outcome: Sendable {
        public var tracks: [RippedTrack]
        public var verification: VerificationResult?
        /// Track numbers that needed a secure re-rip after the fast pass.
        public var reRippedTracks: [Int]
        public var strategy: Strategy
        /// True when the drive's C2 reporting was caught lying — remember
        /// per drive and disable C2 for it in future rips.
        public var c2Unreliable: Bool
        /// Tracks abandoned because they exceeded the per-track time budget.
        public var failedTracks: [Int]
        /// Why the checksum database could not be consulted (network, HTTP,
        /// malformed response). Distinct from `verification == nil` with a
        /// working database, which means "no verifier configured".
        public var verificationError: String?

        public init(
            tracks: [RippedTrack],
            verification: VerificationResult?,
            reRippedTracks: [Int],
            strategy: Strategy,
            c2Unreliable: Bool,
            failedTracks: [Int],
            verificationError: String? = nil
        ) {
            self.tracks = tracks
            self.verification = verification
            self.reRippedTracks = reRippedTracks
            self.strategy = strategy
            self.c2Unreliable = c2Unreliable
            self.failedTracks = failedTracks
            self.verificationError = verificationError
        }

        /// The database verdict in one line, or why there is none.
        public var verificationSummary: String {
            verification?.summary ?? verificationError.map { "CTDB unavailable (\($0))" } ?? "not in CTDB"
        }

        /// One human-readable line describing how the rip was resolved.
        public var summary: String {
            switch strategy {
            case .secureOnly: "Secure rip (no verification database available)"
            case .fast: "Fast rip — \(verificationSummary)"
            case .fastTrusted: "Fast rip, read clean — \(verificationSummary)"
            case .secureReRip(let count):
                "Secure re-rip of \(count) track(s) with read errors — \(verificationSummary)"
            }
        }
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
        let damage = DamageMap()

        // Without a verifier, a fast first pass proves nothing — go straight
        // to the secure engine instead of ripping everything twice.
        if secureRequested, verifier == nil {
            let secure = try await DiscRipper(device: device, configuration: configuration, damage: damage)
                .rip(toc: toc, to: stagingDirectory, progress: progress)
            return Outcome(
                tracks: secure.tracks,
                verification: nil,
                reRippedTracks: [],
                strategy: .secureOnly,
                c2Unreliable: secure.c2Unreliable,
                failedTracks: secure.failedTracks
            )
        }

        // Pass 1: burst, regardless of mode — the database may spare us
        // the slow machinery entirely.
        var burstConfiguration = configuration
        burstConfiguration.mode = .burst
        let firstPass = try await DiscRipper(device: device, configuration: burstConfiguration, damage: damage)
            .rip(toc: toc, to: stagingDirectory, progress: progress)

        var (verification, verificationError) = await verify(
            toc: toc, tracks: firstPass.tracks, discCRC: firstPass.ctdbDiscCRC32
        )

        guard secureRequested else {
            return Outcome(
                tracks: firstPass.tracks,
                verification: verification,
                reRippedTracks: [],
                strategy: .fast,
                c2Unreliable: firstPass.c2Unreliable,
                failedTracks: firstPass.failedTracks,
                verificationError: verificationError
            )
        }

        let unverified = Self.tracksToReRip(firstPass: firstPass, verification: verification)
        if unverified.isEmpty {
            return Outcome(
                tracks: firstPass.tracks,
                verification: verification,
                reRippedTracks: [],
                strategy: .fastTrusted,
                c2Unreliable: firstPass.c2Unreliable,
                failedTracks: firstPass.failedTracks,
                verificationError: verificationError
            )
        }

        // Pass 2: secure re-rip of only the tracks that had read errors. The
        // first pass already found the request size the drive accepts.
        var secureConfiguration = configuration
        secureConfiguration.chunkSectors = firstPass.tunedChunkSectors
        let secondPass = try await DiscRipper(device: device, configuration: secureConfiguration, damage: damage)
            .rip(toc: toc, only: Set(unverified), to: stagingDirectory, progress: progress)

        var merged = firstPass.tracks.filter { !unverified.contains($0.trackNumber) }
        merged.append(contentsOf: secondPass.tracks)
        merged.sort { $0.trackNumber < $1.trackNumber }

        // Re-verify the final state (disc CRC is stale after partial re-rips).
        // The first-pass verdicts are stale for the re-ripped tracks, so a
        // failed re-check reports "unavailable" rather than keeping them.
        (verification, verificationError) = await verify(toc: toc, tracks: merged, discCRC: nil)

        return Outcome(
            tracks: merged,
            verification: verification,
            reRippedTracks: unverified,
            strategy: .secureReRip(trackCount: unverified.count),
            c2Unreliable: firstPass.c2Unreliable || secondPass.c2Unreliable,
            failedTracks: (firstPass.failedTracks + secondPass.failedTracks).sorted(),
            verificationError: verificationError
        )
    }

    /// Which tracks of a burst pass deserve the secure engine.
    ///
    /// Policy ("trust one clean pass"): a clean single read is accepted
    /// unless there's positive evidence it's wrong. Two cases:
    ///
    /// - The disc is in CTDB and at least one track matched — so this IS
    ///   the right pressing/master. A track that then DIFFERS is evidence
    ///   of a read error (the rest of the disc proves the master), so
    ///   re-rip exactly those differing tracks.
    /// - Zero tracks matched — the disc isn't in CTDB, or it's a different
    ///   master/pressing where nothing will ever match (common for
    ///   Enhanced CDs and reissues). Re-reading the same clean sectors
    ///   just reproduces identical bytes, so trust the clean reads and
    ///   re-rip only tracks that hit an actual unreadable sector.
    ///
    /// A track that already exceeded its time budget would just burn
    /// another budget in the secure pass, so it stays failed.
    public static func tracksToReRip(
        firstPass: DiscRipper.DiscRipResult, verification: VerificationResult?
    ) -> [Int] {
        var candidates: [Int]
        if let verification, verification.verifiedCount > 0 {
            candidates = verification.trackVerdicts
                .filter { if case .differs = $0.value { true } else { false } }
                .map(\.key)
        } else {
            candidates = firstPass.tracks
                .filter { !$0.unrecoverableSectors.isEmpty }
                .map(\.trackNumber)
        }
        candidates.removeAll { firstPass.failedTracks.contains($0) }
        return candidates.sorted()
    }

    /// Consults the database; a failure is reported, not disguised as an
    /// absent disc.
    private func verify(
        toc: TOC, tracks: [RippedTrack], discCRC: UInt32?
    ) async -> (VerificationResult?, String?) {
        guard let verifier else { return (nil, nil) }
        let checksums = tracks.reduce(into: [Int: TrackChecksums]()) {
            $0[$1.trackNumber] = $1.checksums
        }
        do {
            return (try await verifier.verify(toc: toc, trackChecksums: checksums, ctdbDiscCRC32: discCRC), nil)
        } catch {
            return (nil, String(describing: error))
        }
    }
}
