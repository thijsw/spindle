import AVFoundation
import Foundation
import Metadata

/// ALAC (.m4a) encoding via Core Audio, with iTunes-style metadata written by
/// a passthrough AVAssetExportSession re-mux.
public struct ALACEncoder: TrackEncoder {
    public init() {}

    public func encode(wav: URL, to destination: URL, tags: TrackTags, art: CoverArt?) async throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).encoding.m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }

        try Self.transcode(wav: wav, to: temporary)
        try await Self.writeTags(from: temporary, to: destination, tags: tags, art: art)
    }

    static func transcode(wav: URL, to destination: URL) throws {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatInt16, interleaved: true)
        } catch {
            throw EncodingError.unreadableInput(wav, String(describing: error))
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: input.fileFormat.sampleRate,
            AVNumberOfChannelsKey: input.fileFormat.channelCount,
            AVEncoderBitDepthHintKey: 16,
        ]

        try? FileManager.default.removeItem(at: destination)
        let output = try AVAudioFile(
            forWriting: destination,
            settings: settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 65536) else {
            throw EncodingError.encodingFailed("cannot allocate buffer")
        }
        // Guard on framePosition: read(into:) throws at exact EOF instead of
        // returning an empty buffer.
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }

    static func writeTags(from source: URL, to destination: URL, tags: TrackTags, art: CoverArt?) async throws {
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw EncodingError.taggingFailed("cannot create export session")
        }

        var items: [AVMetadataItem] = [
            item(.iTunesMetadataSongName, tags.track.title),
            item(.iTunesMetadataArtist, tags.track.artist),
            item(.iTunesMetadataAlbum, tags.album.album),
            item(.iTunesMetadataAlbumArtist, tags.album.albumArtist),
            trackNumberItem(track: tags.track.position, total: tags.trackTotal),
            discNumberItem(disc: tags.album.discNumber, total: tags.album.discTotal),
        ]
        if let date = tags.album.date {
            items.append(item(.iTunesMetadataReleaseDate, date))
        }
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

    private static func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    /// iTunes 'trkn'/'disk' atoms take a packed big-endian byte layout.
    private static func numberPairItem(_ identifier: AVMetadataIdentifier, first: Int, second: Int, trailingZeros: Bool) -> AVMetadataItem {
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

    private static func trackNumberItem(track: Int, total: Int) -> AVMetadataItem {
        numberPairItem(.iTunesMetadataTrackNumber, first: track, second: total, trailingZeros: true)
    }

    private static func discNumberItem(disc: Int, total: Int) -> AVMetadataItem {
        numberPairItem(.iTunesMetadataDiscNumber, first: disc, second: total, trailingZeros: false)
    }
}
