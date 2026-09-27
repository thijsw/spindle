import AVFoundation
import Foundation
import Metadata

/// ALAC or AAC (.m4a) encoding via Core Audio, with iTunes-style metadata
/// written by a passthrough AVAssetExportSession re-mux.
///
/// Tag mapping follows Picard's MP4 conventions: the standard iTunes atoms
/// where one exists, and `----:com.apple.iTunes:<name>` freeform atoms for
/// the MusicBrainz identifiers and the rest, so Navidrome and friends see
/// the same tag set as in FLAC.
public struct M4AEncoder: TrackEncoder {
    public enum Codec: Sendable {
        case alac
        case aac
    }

    /// AAC bitrate (Apple Music's standard for 44.1 kHz stereo).
    private static let aacBitRate = 256_000

    let codec: Codec

    public init(codec: Codec) {
        self.codec = codec
    }

    public func encode(wav: URL, to destination: URL, tags: TrackTags, art: CoverArt?) async throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).encoding.m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }

        _ = try Transcoder.transcode(wav: wav, to: temporary, hashPCM: false) { input in
            var settings: [String: Any] = [
                AVSampleRateKey: input.sampleRate,
                AVNumberOfChannelsKey: input.channelCount,
            ]
            switch codec {
            case .alac:
                settings[AVFormatIDKey] = kAudioFormatAppleLossless
                settings[AVEncoderBitDepthHintKey] = 16
            case .aac:
                settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
                settings[AVEncoderBitRateKey] = Self.aacBitRate
            }
            return settings
        }
        try await Self.writeTags(from: temporary, to: destination, tags: tags, art: art)
    }

    // MARK: Tags

    static func writeTags(from source: URL, to destination: URL, tags: TrackTags, art: CoverArt?) async throws {
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw EncodingError.taggingFailed("cannot create export session")
        }

        var items = tags.fields.compactMap(metadataItem(for:))
        items.append(numberPairItem(
            .iTunesMetadataTrackNumber, first: tags.track.position, second: tags.trackTotal, trailingZeros: true
        ))
        items.append(numberPairItem(
            .iTunesMetadataDiscNumber, first: tags.album.discNumber, second: tags.album.discTotal, trailingZeros: false
        ))
        if let art {
            let artwork = AVMutableMetadataItem()
            artwork.identifier = .iTunesMetadataCoverArt
            artwork.value = art.data as NSData
            artwork.dataType = art.mimeType == "image/png"
                ? kCMMetadataBaseDataType_PNG as String
                : kCMMetadataBaseDataType_JPEG as String
            items.append(artwork)
        }

        export.metadata = items
        export.outputFileType = .m4a
        try? FileManager.default.removeItem(at: destination)
        export.outputURL = destination

        await export.export()
        if let error = export.error {
            throw EncodingError.taggingFailed(String(describing: error))
        }
    }

    /// Where a tag lands in an MP4 container.
    private enum MP4Slot {
        /// A standard iTunes atom.
        case atom(AVMetadataIdentifier)
        /// A `----:com.apple.iTunes:<name>` freeform atom (Picard's name).
        case freeform(String)
    }

    private static func slot(for key: TagKey) -> MP4Slot? {
        switch key {
        case .title: .atom(.iTunesMetadataSongName)
        case .artist: .atom(.iTunesMetadataArtist)
        case .album: .atom(.iTunesMetadataAlbum)
        case .albumArtist: .atom(.iTunesMetadataAlbumArtist)
        case .date: .atom(.iTunesMetadataReleaseDate)
        // Written as the packed trkn/disk atoms instead.
        case .trackNumber, .trackTotal, .discNumber, .discTotal: nil
        case .albumArtistSort: .freeform("ALBUMARTISTSORT")
        case .media: .freeform("MEDIA")
        case .originalDate: .freeform("originaldate")
        case .originalYear: .freeform("originalyear")
        case .label: .freeform("LABEL")
        case .catalogNumber: .freeform("CATALOGNUMBER")
        case .barcode: .freeform("BARCODE")
        case .isrc: .freeform("ISRC")
        case .releaseCountry: .freeform("MusicBrainz Album Release Country")
        case .releaseStatus: .freeform("MusicBrainz Album Status")
        case .musicBrainzAlbumID: .freeform("MusicBrainz Album Id")
        case .musicBrainzReleaseGroupID: .freeform("MusicBrainz Release Group Id")
        case .musicBrainzDiscID: .freeform("MusicBrainz Disc Id")
        case .musicBrainzRecordingID: .freeform("MusicBrainz Track Id")
        case .musicBrainzReleaseTrackID: .freeform("MusicBrainz Release Track Id")
        case .musicBrainzAlbumArtistID: .freeform("MusicBrainz Album Artist Id")
        case .musicBrainzArtistID: .freeform("MusicBrainz Artist Id")
        }
    }

    /// AVFoundation's key space for iTunes freeform ("----") atoms; the key
    /// is the atom's mean and name joined with a dot.
    static let freeformKeySpace = AVMetadataKeySpace(rawValue: "itlk")

    static func freeformIdentifier(name: String) -> AVMetadataIdentifier? {
        AVMetadataItem.identifier(forKey: "com.apple.iTunes.\(name)", keySpace: freeformKeySpace)
    }

    private static func metadataItem(for field: TagField) -> AVMetadataItem? {
        let item = AVMutableMetadataItem()
        switch slot(for: field.key) {
        case nil:
            return nil
        case .atom(let identifier)?:
            item.identifier = identifier
            item.extendedLanguageTag = "und"
        case .freeform(let name)?:
            guard let identifier = freeformIdentifier(name: name) else { return nil }
            item.identifier = identifier
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
        }
        item.value = field.value as NSString
        return item
    }

    /// iTunes 'trkn'/'disk' atoms take a packed big-endian byte layout.
    private static func numberPairItem(
        _ identifier: AVMetadataIdentifier, first: Int, second: Int, trailingZeros: Bool
    ) -> AVMetadataItem {
        var bytes: [UInt8] = [
            0, 0,
            UInt8((first >> 8) & 0xFF), UInt8(first & 0xFF),
            UInt8((second >> 8) & 0xFF), UInt8(second & 0xFF),
        ]
        if trailingZeros { bytes += [0, 0] }
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = Data(bytes) as NSData
        item.dataType = kCMMetadataBaseDataType_RawData as String
        return item
    }
}
