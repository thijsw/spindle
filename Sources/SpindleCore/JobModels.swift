import Foundation
import Metadata
import RipEngine

public struct JobID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: UUID

    public init() {
        self.raw = UUID()
    }

    public var description: String { raw.uuidString }
}

public enum JobStage: Sendable, Equatable {
    case detected
    case readingTOC
    case ripping
    case ripped
    case awaitingMetadata
    case encoding
    case transferring
    case completed
    case failed(String)

    public var label: String {
        switch self {
        case .detected: "Detected"
        case .readingTOC: "Reading disc"
        case .ripping: "Ripping"
        case .ripped: "Ripped"
        case .awaitingMetadata: "Waiting for album choice"
        case .encoding: "Encoding"
        case .transferring: "Transferring"
        case .completed: "Done"
        case .failed(let reason): "Failed: \(reason)"
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed: true
        default: false
        }
    }
}

public struct TrackState: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        case waiting
        case ripping(Double) // 0...1
        case ripped
        case verified(Bool) // CTDB match?
        case encoded
        case transferred
        case failed(String)
    }

    public var number: Int
    public var title: String
    public var durationSeconds: Double
    public var status: Status

    public var id: Int { number }

    public init(number: Int, title: String, durationSeconds: Double, status: Status = .waiting) {
        self.number = number
        self.title = title
        self.durationSeconds = durationSeconds
        self.status = status
    }
}

/// A display-ready release candidate for the picker.
public struct ReleaseCandidate: Sendable, Equatable, Identifiable {
    public let releaseMBID: String
    public let title: String
    public let artist: String
    public let date: String?
    public let country: String?
    public let format: String?
    public let label: String?
    public let catalogNumber: String?
    public let barcode: String?
    public let trackCount: Int
    public let confidence: Double

    public var id: String { releaseMBID }

    public init(ranked: ReleaseScorer.Ranked) {
        let release = ranked.release
        let medium = release.media?.first
        self.releaseMBID = release.id
        self.title = release.title
        self.artist = (release.artistCredit ?? []).joinedName
        self.date = release.date
        self.country = release.country
        self.format = medium?.format
        self.label = release.labelInfo?.first?.label?.name
        self.catalogNumber = release.labelInfo?.first?.catalogNumber
        self.barcode = release.barcode
        self.trackCount = medium?.trackCount ?? medium?.tracks?.count ?? 0
        self.confidence = ranked.confidence
    }
}

/// Everything the UI needs to render one disc job. Immutable snapshot,
/// re-emitted whenever the job changes.
public struct JobSnapshot: Sendable, Equatable, Identifiable {
    public var id: JobID
    public var bsdName: String
    public var stage: JobStage
    public var discID: String?
    public var album: ResolvedAlbum?
    public var artData: Data?
    public var tracks: [TrackState]
    public var candidates: [ReleaseCandidate]
    public var verificationSummary: String?
    public var startedAt: Date
    public var finishedAt: Date?

    public var displayTitle: String {
        album.map { "\($0.albumArtist) — \($0.album)" } ?? "Audio CD"
    }
}

/// Persisted record of a finished (or failed) job for the history list.
public struct JobRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: JobID
    public var album: String
    public var artist: String
    public var succeeded: Bool
    public var detail: String?
    public var trackCount: Int
    public var finishedAt: Date

    public init(snapshot: JobSnapshot) {
        self.id = snapshot.id
        self.album = snapshot.album?.album ?? "Unknown Album"
        self.artist = snapshot.album?.albumArtist ?? "Unknown Artist"
        if case .failed(let reason) = snapshot.stage {
            self.succeeded = false
            self.detail = reason
        } else {
            self.succeeded = true
            self.detail = snapshot.verificationSummary
        }
        self.trackCount = snapshot.tracks.count
        self.finishedAt = snapshot.finishedAt ?? Date()
    }
}

public enum PipelineEvent: Sendable {
    case jobUpdated(JobSnapshot)
    case releaseChoiceNeeded(JobID)
    case notify(title: String, body: String)
}
