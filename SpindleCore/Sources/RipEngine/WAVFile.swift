import Foundation

/// Streaming writer for 16-bit/44.1 kHz stereo little-endian WAV files —
/// the staging format between ripping and encoding.
public final class WAVWriter {
    public enum WAVError: Error {
        case cannotCreate(URL)
    }

    private let handle: FileHandle
    private var dataBytes: UInt32 = 0
    public let url: URL

    private static let headerSize = 44

    /// When the audio length is known in advance (it always is for a CD
    /// track), the final header is written immediately so the file is a
    /// valid, playable WAV even while the rip is still appending to it.
    public init(url: URL, expectedDataBytes: Int? = nil) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw WAVError.cannotCreate(url)
        }
        self.handle = handle
        self.url = url
        if let expectedDataBytes {
            try handle.write(contentsOf: Self.header(dataBytes: UInt32(expectedDataBytes)))
        } else {
            try handle.write(contentsOf: Data(count: Self.headerSize)) // placeholder
        }
    }

    public func append(_ audio: Data) throws {
        try handle.write(contentsOf: audio)
        dataBytes += UInt32(audio.count)
    }

    public func finish() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataBytes: dataBytes))
        try handle.close()
    }

    private static func header(dataBytes: UInt32) -> Data {
        var header = Data(capacity: headerSize)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }

        header.append(contentsOf: "RIFF".utf8)
        u32(36 + dataBytes)
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        u32(16) // PCM fmt chunk size
        u16(1) // PCM
        u16(2) // channels
        u32(44100)
        u32(44100 * 4) // byte rate
        u16(4) // block align
        u16(16) // bits per sample
        header.append(contentsOf: "data".utf8)
        u32(dataBytes)
        return header
    }
}
