import AVFoundation
import CryptoKit
import Foundation

/// The WAV → Core Audio encode loop shared by every output format.
enum Transcoder {
    /// Encodes `wav` into `destination`. `settings` receives the input file
    /// format so the output can mirror its sample rate and channel count.
    /// Returns the MD5 of the raw interleaved 16-bit PCM when `hashPCM` is
    /// set (FLAC's STREAMINFO needs it; Apple's encoder doesn't write it).
    ///
    /// Runs synchronously on the caller's executor; the pipeline dispatches
    /// encode jobs onto background tasks.
    static func transcode(
        wav: URL,
        to destination: URL,
        hashPCM: Bool,
        settings: (AVAudioFormat) -> [String: Any]
    ) throws -> Data? {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatInt16, interleaved: true)
        } catch {
            throw EncodingError.unreadableInput(wav, String(describing: error))
        }

        try? FileManager.default.removeItem(at: destination)
        let output: AVAudioFile
        do {
            output = try AVAudioFile(
                forWriting: destination,
                settings: settings(input.fileFormat),
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            throw EncodingError.encodingFailed("cannot create \(destination.lastPathComponent): \(error)")
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 65536) else {
            throw EncodingError.encodingFailed("cannot allocate buffer")
        }

        var md5: Insecure.MD5? = hashPCM ? Insecure.MD5() : nil
        // Guard on framePosition: read(into:) throws at exact EOF instead of
        // returning an empty buffer.
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            if md5 != nil, let channelData = buffer.int16ChannelData {
                let bytes = Int(buffer.frameLength) * Int(input.processingFormat.channelCount) * 2
                md5?.update(bufferPointer: UnsafeRawBufferPointer(start: channelData[0], count: bytes))
            }
            try output.write(from: buffer)
        }
        return md5.map { Data($0.finalize()) }
    }
}
