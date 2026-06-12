import Foundation
import Metadata

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

    /// The Picard-compatible Vorbis comment set Navidrome and friends expect.
    /// Order is stable; multi-value fields repeat the key.
    public var vorbisComments: [(String, String)] {
        var comments: [(String, String)] = [
            ("TITLE", track.title),
            ("ARTIST", track.artist),
            ("ALBUM", album.album),
            ("ALBUMARTIST", album.albumArtist),
            ("TRACKNUMBER", String(track.position)),
            ("TRACKTOTAL", String(trackTotal)),
            ("DISCNUMBER", String(album.discNumber)),
            ("DISCTOTAL", String(album.discTotal)),
            ("MEDIA", album.media),
        ]

        func add(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { comments.append((key, value)) }
        }

        add("ALBUMARTISTSORT", album.albumArtistSort)
        add("DATE", album.date)
        add("ORIGINALDATE", album.originalDate)
        if let original = album.originalDate, original.count >= 4 {
            add("ORIGINALYEAR", String(original.prefix(4)))
        }
        add("LABEL", album.label)
        add("CATALOGNUMBER", album.catalogNumber)
        add("BARCODE", album.barcode)
        add("ISRC", track.isrc)
        add("RELEASECOUNTRY", album.country)
        add("RELEASESTATUS", album.status?.lowercased())
        add("MUSICBRAINZ_ALBUMID", album.releaseMBID)
        add("MUSICBRAINZ_RELEASEGROUPID", album.releaseGroupMBID)
        add("MUSICBRAINZ_DISCID", album.discID)
        // Picard maps MUSICBRAINZ_TRACKID to the *recording* MBID.
        add("MUSICBRAINZ_TRACKID", track.recordingMBID)
        add("MUSICBRAINZ_RELEASETRACKID", track.trackMBID)
        for id in album.albumArtistMBIDs {
            comments.append(("MUSICBRAINZ_ALBUMARTISTID", id))
        }
        for id in track.artistMBIDs {
            comments.append(("MUSICBRAINZ_ARTISTID", id))
        }
        return comments
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
