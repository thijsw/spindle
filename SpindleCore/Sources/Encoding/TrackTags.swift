import Foundation
import Metadata

/// One tag, independent of the container format.
public struct TagField: Sendable, Equatable {
    public let key: TagKey
    public let value: String

    public init(_ key: TagKey, _ value: String) {
        self.key = key
        self.value = value
    }
}

/// The Picard tag vocabulary Spindle writes. Each container maps it to its
/// own names (Vorbis comments in FLAC, iTunes atoms in M4A) so every format
/// carries the same information.
public enum TagKey: String, Sendable, CaseIterable {
    case title, artist, album, albumArtist
    case trackNumber, trackTotal, discNumber, discTotal, media
    case albumArtistSort, date, originalDate, originalYear
    case label, catalogNumber, barcode, isrc, releaseCountry, releaseStatus
    case musicBrainzAlbumID, musicBrainzReleaseGroupID, musicBrainzDiscID
    /// Picard maps MUSICBRAINZ_TRACKID to the *recording* MBID.
    case musicBrainzRecordingID
    case musicBrainzReleaseTrackID, musicBrainzAlbumArtistID, musicBrainzArtistID

    /// Picard's Vorbis comment name.
    public var vorbisName: String {
        switch self {
        case .title: "TITLE"
        case .artist: "ARTIST"
        case .album: "ALBUM"
        case .albumArtist: "ALBUMARTIST"
        case .trackNumber: "TRACKNUMBER"
        case .trackTotal: "TRACKTOTAL"
        case .discNumber: "DISCNUMBER"
        case .discTotal: "DISCTOTAL"
        case .media: "MEDIA"
        case .albumArtistSort: "ALBUMARTISTSORT"
        case .date: "DATE"
        case .originalDate: "ORIGINALDATE"
        case .originalYear: "ORIGINALYEAR"
        case .label: "LABEL"
        case .catalogNumber: "CATALOGNUMBER"
        case .barcode: "BARCODE"
        case .isrc: "ISRC"
        case .releaseCountry: "RELEASECOUNTRY"
        case .releaseStatus: "RELEASESTATUS"
        case .musicBrainzAlbumID: "MUSICBRAINZ_ALBUMID"
        case .musicBrainzReleaseGroupID: "MUSICBRAINZ_RELEASEGROUPID"
        case .musicBrainzDiscID: "MUSICBRAINZ_DISCID"
        case .musicBrainzRecordingID: "MUSICBRAINZ_TRACKID"
        case .musicBrainzReleaseTrackID: "MUSICBRAINZ_RELEASETRACKID"
        case .musicBrainzAlbumArtistID: "MUSICBRAINZ_ALBUMARTISTID"
        case .musicBrainzArtistID: "MUSICBRAINZ_ARTISTID"
        }
    }
}

/// Everything written into one track's tags.
public struct TrackTags: Sendable {
    public var album: ResolvedAlbum
    public var track: ResolvedTrack
    public var trackTotal: Int

    public init(album: ResolvedAlbum, track: ResolvedTrack) {
        self.album = album
        self.track = track
        self.trackTotal = album.tracks.count
    }

    /// The canonical tag set, in a stable order; multi-value fields repeat
    /// the key. Empty values are omitted.
    public var fields: [TagField] {
        var fields: [TagField] = [
            TagField(.title, track.title),
            TagField(.artist, track.artist),
            TagField(.album, album.album),
            TagField(.albumArtist, album.albumArtist),
            TagField(.trackNumber, String(track.position)),
            TagField(.trackTotal, String(trackTotal)),
            TagField(.discNumber, String(album.discNumber)),
            TagField(.discTotal, String(album.discTotal)),
            TagField(.media, album.media),
        ]

        func add(_ key: TagKey, _ value: String?) {
            if let value, !value.isEmpty { fields.append(TagField(key, value)) }
        }

        add(.albumArtistSort, album.albumArtistSort)
        add(.date, album.date)
        add(.originalDate, album.originalDate)
        add(.originalYear, album.originalYear)
        add(.label, album.label)
        add(.catalogNumber, album.catalogNumber)
        add(.barcode, album.barcode)
        add(.isrc, track.isrc)
        add(.releaseCountry, album.country)
        add(.releaseStatus, album.status?.lowercased())
        add(.musicBrainzAlbumID, album.releaseMBID)
        add(.musicBrainzReleaseGroupID, album.releaseGroupMBID)
        add(.musicBrainzDiscID, album.discID)
        add(.musicBrainzRecordingID, track.recordingMBID)
        add(.musicBrainzReleaseTrackID, track.trackMBID)
        for id in album.albumArtistMBIDs {
            add(.musicBrainzAlbumArtistID, id)
        }
        for id in track.artistMBIDs {
            add(.musicBrainzArtistID, id)
        }
        return fields
    }

    /// The Picard-compatible Vorbis comment set Navidrome and friends expect.
    public var vorbisComments: [(String, String)] {
        fields.map { ($0.key.vorbisName, $0.value) }
    }
}

public enum AudioFormat: String, Sendable, Codable, CaseIterable {
    case flac
    case alac
    case aac

    public var fileExtension: String {
        switch self {
        case .flac: "flac"
        case .alac, .aac: "m4a"
        }
    }

    /// The encoder that produces this format.
    public func makeEncoder() -> any TrackEncoder {
        switch self {
        case .flac: FLACEncoder()
        case .alac: M4AEncoder(codec: .alac)
        case .aac: M4AEncoder(codec: .aac)
        }
    }
}

public protocol TrackEncoder: Sendable {
    /// Encodes a staging WAV into the destination file with tags and art.
    func encode(wav: URL, to destination: URL, tags: TrackTags, art: CoverArt?) async throws
}

public enum EncodingError: Error, CustomStringConvertible, Sendable {
    case unreadableInput(URL, String)
    case encodingFailed(String)
    case notAFLACFile(URL)
    case malformedFLAC(String)
    case taggingFailed(String)

    public var description: String {
        switch self {
        case .unreadableInput(let url, let detail): "Cannot read \(url.lastPathComponent): \(detail)"
        case .encodingFailed(let detail): "Encoding failed: \(detail)"
        case .notAFLACFile(let url): "\(url.lastPathComponent) is not a FLAC file"
        case .malformedFLAC(let detail): "Malformed FLAC structure: \(detail)"
        case .taggingFailed(let detail): "Tagging failed: \(detail)"
        }
    }
}
