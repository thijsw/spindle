import AVFoundation
import CryptoKit
import Foundation
import Metadata

/// FLAC encoding via Core Audio (AVAudioFile), then a metadata rewrite to add
/// Vorbis comments, embedded art, and the PCM MD5 that Apple's encoder omits.
public struct FLACEncoder: TrackEncoder {
    public init() {}

    public func encode(wav: URL, to destination: URL, tags: TrackTags, art: CoverArt?) async throws {
        let md5 = try Self.transcode(wav: wav, to: destination)
        try FLACMetadata.rewrite(
            fileURL: destination,
            vorbisComments: tags.vorbisComments,
            picture: art.map { (data: $0.data, mimeType: $0.mimeType) },
            pcmMD5: md5
        )
    }

    /// Encodes WAV → FLAC and returns the MD5 of the raw PCM stream.
    /// Runs synchronously on the caller's executor; encode jobs are
    /// dispatched onto background tasks by the pipeline.
    static func transcode(wav: URL, to destination: URL) throws -> Data {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatInt16, interleaved: true)
        } catch {
            throw EncodingError.unreadableInput(wav, String(describing: error))
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: input.fileFormat.sampleRate,
            AVNumberOfChannelsKey: input.fileFormat.channelCount,
            AVEncoderBitDepthHintKey: 16,
        ]

        try? FileManager.default.removeItem(at: destination)
        let output: AVAudioFile
        do {
            output = try AVAudioFile(
                forWriting: destination,
                settings: settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            throw EncodingError.encodingFailed("cannot create \(destination.lastPathComponent): \(error)")
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: input.processingFormat,
            frameCapacity: 65536
        ) else {
            throw EncodingError.encodingFailed("cannot allocate buffer")
        }

        var md5 = Insecure.MD5()
        // Guard on framePosition: read(into:) throws at exact EOF instead of
        // returning an empty buffer.
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            if let channelData = buffer.int16ChannelData {
                let bytes = Int(buffer.frameLength) * Int(input.processingFormat.channelCount) * 2
                md5.update(bufferPointer: UnsafeRawBufferPointer(start: channelData[0], count: bytes))
            }
            try output.write(from: buffer)
        }
        return Data(md5.finalize())
    }
}
