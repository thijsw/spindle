import Foundation

/// The canonical tagging input: one chosen release applied to one disc.
public struct ResolvedAlbum: Sendable, Hashable, Codable {
    public var album: String
    public var albumArtist: String
    public var albumArtistSort: String?
    public var albumArtistMBIDs: [String]
    public var releaseMBID: String?
    public var releaseGroupMBID: String?
    public var discID: String?
    public var date: String?
    public var originalDate: String?
    public var country: String?
    public var label: String?
    public var catalogNumber: String?
    public var barcode: String?
    public var status: String?
    public var media: String
    public var discNumber: Int
    public var discTotal: Int
    public var tracks: [ResolvedTrack]

    public init(
        album: String,
        albumArtist: String,
        albumArtistSort: String? = nil,
        albumArtistMBIDs: [String] = [],
        releaseMBID: String? = nil,
        releaseGroupMBID: String? = nil,
        discID: String? = nil,
        date: String? = nil,
        originalDate: String? = nil,
        country: String? = nil,
        label: String? = nil,
        catalogNumber: String? = nil,
        barcode: String? = nil,
        status: String? = nil,
        media: String = "CD",
        discNumber: Int = 1,
        discTotal: Int = 1,
        tracks: [ResolvedTrack]
    ) {
        self.album = album
        self.albumArtist = albumArtist
        self.albumArtistSort = albumArtistSort
        self.albumArtistMBIDs = albumArtistMBIDs
        self.releaseMBID = releaseMBID
        self.releaseGroupMBID = releaseGroupMBID
        self.discID = discID
        self.date = date
        self.originalDate = originalDate
        self.country = country
        self.label = label
        self.catalogNumber = catalogNumber
        self.barcode = barcode
        self.status = status
        self.media = media
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.tracks = tracks
    }

    public var year: String? {
        date.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil }
    }
}

public struct ResolvedTrack: Sendable, Hashable, Codable {
    public var position: Int
    public var title: String
    public var artist: String
    public var artistMBIDs: [String]
    public var recordingMBID: String?
    public var trackMBID: String?
    public var isrc: String?

    public init(
        position: Int,
        title: String,
        artist: String,
        artistMBIDs: [String] = [],
        recordingMBID: String? = nil,
        trackMBID: String? = nil,
        isrc: String? = nil
    ) {
        self.position = position
        self.title = title
        self.artist = artist
        self.artistMBIDs = artistMBIDs
        self.recordingMBID = recordingMBID
        self.trackMBID = trackMBID
        self.isrc = isrc
    }
}

extension ResolvedAlbum {
    /// Builds tagging input from a chosen MusicBrainz release. The medium is
    /// matched by DiscID when possible, then by audio track count.
    public init?(release: MBRelease, discID: String?, audioTrackCount: Int) {
        let media = release.media ?? []
        let medium = media.first { medium in
            discID != nil && (medium.discs ?? []).contains { $0.id == discID }
        }
            ?? media.first { ($0.trackCount ?? $0.tracks?.count) == audioTrackCount }
            ?? media.first
        guard let medium else { return nil }

        let credit = release.artistCredit ?? []
        let albumArtist = credit.isEmpty ? "Unknown Artist" : credit.joinedName

        let tracks: [ResolvedTrack] = (medium.tracks ?? []).enumerated().map { index, track in
            let trackCredit = track.recording?.artistCredit ?? credit
            return ResolvedTrack(
                position: track.position ?? index + 1,
                title: track.title ?? track.recording?.title ?? "Track \(index + 1)",
                artist: trackCredit.isEmpty ? albumArtist : trackCredit.joinedName,
                artistMBIDs: trackCredit.map(\.artist.id),
                recordingMBID: track.recording?.id,
                trackMBID: track.id
            )
        }

        self.init(
            album: release.title,
            albumArtist: albumArtist,
            albumArtistSort: credit.first?.artist.sortName,
            albumArtistMBIDs: credit.map(\.artist.id),
            releaseMBID: release.id,
            releaseGroupMBID: release.releaseGroup?.id,
            discID: discID,
            date: release.date,
            originalDate: release.releaseGroup?.firstReleaseDate,
            country: release.country,
            label: release.labelInfo?.first?.label?.name,
            catalogNumber: release.labelInfo?.first?.catalogNumber,
            barcode: release.barcode,
            status: release.status,
            media: medium.format ?? "CD",
            discNumber: medium.position ?? 1,
            discTotal: max(media.count, 1),
            tracks: tracks
        )
    }

    /// Fallback metadata from CD-TEXT, or generic names when nothing is known.
    public static func fallback(cdText: CDTextInfo?, discID: String?, trackCount: Int) -> ResolvedAlbum {
        let shortID = discID.map { String($0.prefix(8)) } ?? "Unknown"
        let tracks = (1...max(trackCount, 1)).map { n in
            ResolvedTrack(
                position: n,
                title: cdText?.trackTitles[n] ?? String(format: "Track %02d", n),
                artist: cdText?.trackPerformers[n] ?? cdText?.albumPerformer ?? "Unknown Artist"
            )
        }
        return ResolvedAlbum(
            album: cdText?.albumTitle ?? "Unknown Album (\(shortID))",
            albumArtist: cdText?.albumPerformer ?? "Unknown Artist",
            discID: discID,
            tracks: tracks
        )
    }
}
