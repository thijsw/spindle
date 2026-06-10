import DiscDrive
import Foundation
import RipEngine

public enum TrackVerdict: Sendable, Equatable {
    /// The track's CTDB CRC matches an entry with this summed confidence.
    case accuratelyRipped(confidence: Int)
    /// Entries exist for this disc but none match our checksum.
    case differs(bestConfidence: Int)
    /// The disc isn't in the database (neutral — common for obscure releases).
    case notInDatabase
}

public struct VerificationResult: Sendable {
    public let entries: [CTDBEntry]
    public let trackVerdicts: [Int: TrackVerdict] // keyed by track number
    /// Entry whose whole-disc CRC matches ours exactly (strongest outcome).
    public let discMatch: CTDBEntry?

    public var summary: String {
        if entries.isEmpty { return "Not in CTDB" }
        let accurate = trackVerdicts.values.filter {
            if case .accuratelyRipped = $0 { return true } else { return false }
        }.count
        return "\(accurate)/\(trackVerdicts.count) tracks verified (CTDB, \(entries.count) entries)"
    }
}

/// Pluggable verification backend. CTDB ships in v1; AccurateRip can join
/// once written permission for database access is granted.
public protocol RipVerifier: Sendable {
    func verify(
        toc: TOC,
        trackChecksums: [Int: TrackChecksums],
        ctdbDiscCRC32: UInt32?
    ) async throws -> VerificationResult
}

public struct CTDBVerifier: RipVerifier {
    private let client: CTDBClient

    public init(userAgent: String) {
        self.client = CTDBClient(userAgent: userAgent)
    }

    public init(client: CTDBClient) {
        self.client = client
    }

    public func verify(
        toc: TOC,
        trackChecksums: [Int: TrackChecksums],
        ctdbDiscCRC32: UInt32?
    ) async throws -> VerificationResult {
        let entries = try await client.lookup(toc: toc)
        return Self.match(
            entries: entries,
            audioTrackNumbers: toc.audioTracks.map(\.number),
            trackChecksums: trackChecksums,
            ctdbDiscCRC32: ctdbDiscCRC32
        )
    }

    /// Pure matching logic, separated for testability.
    public static func match(
        entries: [CTDBEntry],
        audioTrackNumbers: [Int],
        trackChecksums: [Int: TrackChecksums],
        ctdbDiscCRC32: UInt32?
    ) -> VerificationResult {
        guard !entries.isEmpty else {
            return VerificationResult(
                entries: [],
                trackVerdicts: audioTrackNumbers.reduce(into: [:]) { $0[$1] = .notInDatabase },
                discMatch: nil
            )
        }

        var verdicts: [Int: TrackVerdict] = [:]
        for (index, trackNumber) in audioTrackNumbers.enumerated() {
            guard let checksums = trackChecksums[trackNumber] else { continue }
            var matchedConfidence = 0
            var bestConfidence = 0
            for entry in entries where index < entry.trackCRC32s.count {
                bestConfidence = max(bestConfidence, entry.confidence)
                if entry.trackCRC32s[index] == checksums.ctdbCRC32 {
                    matchedConfidence += entry.confidence
                }
            }
            verdicts[trackNumber] = matchedConfidence > 0
                ? .accuratelyRipped(confidence: matchedConfidence)
                : .differs(bestConfidence: bestConfidence)
        }

        let discMatch = ctdbDiscCRC32.flatMap { crc in
            entries.first { $0.discCRC32 == crc }
        }
        return VerificationResult(entries: entries, trackVerdicts: verdicts, discMatch: discMatch)
    }
}
