import AVFoundation
import Foundation
import Metadata

/// FLAC encoding via Core Audio (AVAudioFile), then a metadata rewrite to add
/// Vorbis comments, embedded art, and the PCM MD5 that Apple's encoder omits.
public struct FLACEncoder: TrackEncoder {
    public init() {}

    public func encode(wav: URL, to destination: URL, tags: TrackTags, art: CoverArt?) async throws {
        let md5 = try Transcoder.transcode(wav: wav, to: destination, hashPCM: true) { input in
            [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: input.sampleRate,
                AVNumberOfChannelsKey: input.channelCount,
                AVEncoderBitDepthHintKey: 16,
            ]
        }
        try FLACMetadata.rewrite(
            fileURL: destination,
            vorbisComments: tags.vorbisComments,
            picture: art,
            pcmMD5: md5
        )
    }
}
