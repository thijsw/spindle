import Foundation

// Decodable models for the MusicBrainz WS/2 JSON responses we consume
// (discid lookup with inc=recordings+artist-credits+release-groups+labels+isrcs).

public struct MBDiscIDResponse: Decodable, Sendable {
    public let releases: [MBRelease]?
}

public struct MBRelease: Decodable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let status: String?
    public let date: String?
    public let country: String?
    public let barcode: String?
    public let releaseGroup: MBReleaseGroup?
    public let artistCredit: [MBArtistCredit]?
    public let labelInfo: [MBLabelInfo]?
    public let media: [MBMedium]?

    enum CodingKeys: String, CodingKey {
        case id, title, status, date, country, barcode, media
        case releaseGroup = "release-group"
        case artistCredit = "artist-credit"
        case labelInfo = "label-info"
    }
}

public struct MBReleaseGroup: Decodable, Sendable {
    public let id: String
    public let firstReleaseDate: String?

    enum CodingKeys: String, CodingKey {
        case id
        case firstReleaseDate = "first-release-date"
    }
}

public struct MBArtistCredit: Decodable, Sendable {
    public let name: String
    public let joinphrase: String?
    public let artist: MBArtist
}

public struct MBArtist: Decodable, Sendable {
    public let id: String
    public let name: String
    public let sortName: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case sortName = "sort-name"
    }
}

public struct MBLabelInfo: Decodable, Sendable {
    public let catalogNumber: String?
    public let label: MBLabel?

    enum CodingKeys: String, CodingKey {
        case catalogNumber = "catalog-number"
        case label
    }
}

public struct MBLabel: Decodable, Sendable {
    public let name: String?
}

public struct MBMedium: Decodable, Sendable {
    public let position: Int?
    public let format: String?
    public let trackCount: Int?
    public let discs: [MBDiscRef]?
    public let tracks: [MBTrack]?

    enum CodingKeys: String, CodingKey {
        case position, format, discs, tracks
        case trackCount = "track-count"
    }
}

public struct MBDiscRef: Decodable, Sendable {
    public let id: String
}

public struct MBTrack: Decodable, Sendable {
    public let id: String
    public let position: Int?
    public let title: String?
    public let recording: MBRecording?
}

public struct MBRecording: Decodable, Sendable {
    public let id: String
    public let title: String?
    public let artistCredit: [MBArtistCredit]?
    /// Requires `inc=isrcs`; a recording can carry several.
    public let isrcs: [String]?

    enum CodingKeys: String, CodingKey {
        case id, title, isrcs
        case artistCredit = "artist-credit"
    }
}

extension MBMedium {
    /// Track count as reported, or counted from the track list.
    public var effectiveTrackCount: Int? { trackCount ?? tracks?.count }

    public func contains(discID: String) -> Bool {
        (discs ?? []).contains { $0.id == discID }
    }
}

extension MBRelease {
    /// The medium that is our disc: matched by DiscID when possible, then by
    /// audio track count, then the first one.
    public func bestMedium(discID: String?, audioTrackCount: Int) -> MBMedium? {
        let media = media ?? []
        if let discID, let byDiscID = media.first(where: { $0.contains(discID: discID) }) {
            return byDiscID
        }
        return media.first { $0.effectiveTrackCount == audioTrackCount } ?? media.first
    }

    /// The label/catalog pair shown for the release (MusicBrainz lists
    /// several for co-releases; the first is the primary).
    public var primaryLabelInfo: MBLabelInfo? { labelInfo?.first }
}

extension [MBArtistCredit] {
    /// Joins an artist credit into a display string ("A feat. B").
    public var joinedName: String {
        map { $0.name + ($0.joinphrase ?? "") }.joined()
    }
}
