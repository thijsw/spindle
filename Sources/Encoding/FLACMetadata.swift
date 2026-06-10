import Foundation

/// Reads and rewrites FLAC metadata blocks. Core Audio's FLAC encoder cannot
/// write Vorbis comments or pictures, so Spindle rewrites the header chain
/// (STREAMINFO with a patched PCM MD5, VORBIS_COMMENT, PICTURE, PADDING) and
/// streams the audio frames through untouched.
public enum FLACMetadata {
    static let magic = Data("fLaC".utf8)

    public struct Block: Sendable {
        public let type: UInt8 // 0 STREAMINFO, 1 PADDING, 4 VORBIS_COMMENT, 6 PICTURE
        public let data: Data
    }

    public struct ParsedFile: Sendable {
        public let blocks: [Block]
        /// Offset of the first audio frame in the file.
        public let framesOffset: Int

        public var streamInfo: Data? { blocks.first { $0.type == 0 }?.data }

        public var vendorString: String? {
            guard let comment = blocks.first(where: { $0.type == 4 })?.data,
                  comment.count >= 4
            else { return nil }
            let length = Int(comment.readLEUInt32(at: 0))
            guard comment.count >= 4 + length else { return nil }
            return String(data: comment.subdata(in: 4 ..< 4 + length), encoding: .utf8)
        }

        /// All KEY=value comments, uppercased keys.
        public var comments: [(String, String)] {
            guard let data = blocks.first(where: { $0.type == 4 })?.data, data.count >= 8 else { return [] }
            var offset = 4 + Int(data.readLEUInt32(at: 0))
            guard data.count >= offset + 4 else { return [] }
            let count = Int(data.readLEUInt32(at: offset))
            offset += 4
            var result: [(String, String)] = []
            for _ in 0 ..< count {
                guard data.count >= offset + 4 else { break }
                let length = Int(data.readLEUInt32(at: offset))
                offset += 4
                guard data.count >= offset + length else { break }
                if let entry = String(data: data.subdata(in: offset ..< offset + length), encoding: .utf8),
                   let eq = entry.firstIndex(of: "=") {
                    result.append((String(entry[..<eq]).uppercased(), String(entry[entry.index(after: eq)...])))
                }
                offset += length
            }
            return result
        }

        public var pictureData: Data? {
            guard let pic = blocks.first(where: { $0.type == 6 })?.data, pic.count > 32 else { return nil }
            var offset = 4
            let mimeLength = Int(pic.readBEUInt32(at: offset)); offset += 4 + mimeLength
            let descLength = Int(pic.readBEUInt32(at: offset)); offset += 4 + descLength
            offset += 16 // width, height, depth, colors
            guard pic.count >= offset + 4 else { return nil }
            let dataLength = Int(pic.readBEUInt32(at: offset)); offset += 4
            guard pic.count >= offset + dataLength else { return nil }
            return pic.subdata(in: offset ..< offset + dataLength)
        }
    }

    public static func parse(fileURL: URL) throws -> ParsedFile {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            throw EncodingError.unreadableInput(fileURL, "cannot open")
        }
        defer { try? handle.close() }

        guard let head = try handle.read(upToCount: 4), head == magic else {
            throw EncodingError.notAFLACFile(fileURL)
        }

        var blocks: [Block] = []
        var offset = 4
        while true {
            guard let header = try handle.read(upToCount: 4), header.count == 4 else {
                throw EncodingError.malformedFLAC("truncated block header at \(offset)")
            }
            let isLast = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard let data = try handle.read(upToCount: length), data.count == length else {
                throw EncodingError.malformedFLAC("truncated block body at \(offset)")
            }
            blocks.append(Block(type: type, data: data))
            offset += 4 + length
            if isLast { break }
        }

        guard blocks.first?.type == 0, blocks[0].data.count == 34 else {
            throw EncodingError.malformedFLAC("missing or invalid STREAMINFO")
        }
        return ParsedFile(blocks: blocks, framesOffset: offset)
    }

    /// Rewrites `fileURL` in place (via a temporary sibling) with the given
    /// metadata. Audio frames are stream-copied.
    public static func rewrite(
        fileURL: URL,
        vorbisComments: [(String, String)],
        picture: (data: Data, mimeType: String)?,
        pcmMD5: Data?,
        paddingBytes: Int = 8192
    ) throws {
        let parsed = try parse(fileURL: fileURL)
        guard var streamInfo = parsed.streamInfo else {
            throw EncodingError.malformedFLAC("no STREAMINFO")
        }
        if let pcmMD5, pcmMD5.count == 16 {
            streamInfo.replaceSubrange(18 ..< 34, with: pcmMD5)
        }

        var header = Data()
        header.append(magic)
        appendBlock(&header, type: 0, data: streamInfo, isLast: false)
        appendBlock(
            &header,
            type: 4,
            data: vorbisCommentBlock(vendor: parsed.vendorString ?? "Spindle", comments: vorbisComments),
            isLast: false
        )
        if let picture {
            appendBlock(&header, type: 6, data: pictureBlock(picture.data, mimeType: picture.mimeType), isLast: false)
        }
        appendBlock(&header, type: 1, data: Data(count: paddingBytes), isLast: true)

        let temporary = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).rewriting")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: temporary),
              let input = try? FileHandle(forReadingFrom: fileURL)
        else {
            throw EncodingError.taggingFailed("cannot open temporary file")
        }
        defer {
            try? input.close()
            try? FileManager.default.removeItem(at: temporary)
        }

        do {
            try output.write(contentsOf: header)
            try input.seek(toOffset: UInt64(parsed.framesOffset))
            while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.close()
        } catch {
            try? output.close()
            throw EncodingError.taggingFailed(String(describing: error))
        }

        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
    }

    private static func appendBlock(_ out: inout Data, type: UInt8, data: Data, isLast: Bool) {
        out.append(type | (isLast ? 0x80 : 0))
        out.append(UInt8((data.count >> 16) & 0xFF))
        out.append(UInt8((data.count >> 8) & 0xFF))
        out.append(UInt8(data.count & 0xFF))
        out.append(data)
    }

    private static func vorbisCommentBlock(vendor: String, comments: [(String, String)]) -> Data {
        var block = Data()
        let vendorBytes = Data(vendor.utf8)
        block.appendLEUInt32(UInt32(vendorBytes.count))
        block.append(vendorBytes)
        block.appendLEUInt32(UInt32(comments.count))
        for (key, value) in comments {
            let entry = Data("\(key)=\(value)".utf8)
            block.appendLEUInt32(UInt32(entry.count))
            block.append(entry)
        }
        return block
    }

    private static func pictureBlock(_ image: Data, mimeType: String) -> Data {
        let dimensions = ImageDimensions.probe(image)
        var block = Data()
        block.appendBEUInt32(3) // front cover
        let mime = Data(mimeType.utf8)
        block.appendBEUInt32(UInt32(mime.count))
        block.append(mime)
        block.appendBEUInt32(0) // empty description
        block.appendBEUInt32(UInt32(dimensions?.width ?? 0))
        block.appendBEUInt32(UInt32(dimensions?.height ?? 0))
        block.appendBEUInt32(UInt32(dimensions?.bitsPerPixel ?? 0))
        block.appendBEUInt32(0) // not an indexed image
        block.appendBEUInt32(UInt32(image.count))
        block.append(image)
        return block
    }
}

/// Minimal JPEG/PNG header probe for the FLAC PICTURE block dimensions.
enum ImageDimensions {
    static func probe(_ data: Data) -> (width: Int, height: Int, bitsPerPixel: Int)? {
        if data.count > 24, data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            // PNG: IHDR is always first — width/height at 16, bit depth + color type at 24.
            let width = Int(data.readBEUInt32(at: 16))
            let height = Int(data.readBEUInt32(at: 20))
            let bitDepth = Int(data[data.startIndex + 24])
            let colorType = Int(data[data.startIndex + 25])
            let channels = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][colorType] ?? 3
            return (width, height, bitDepth * channels)
        }
        if data.count > 4, data.prefix(2) == Data([0xFF, 0xD8]) {
            // JPEG: walk segments to the first SOF marker.
            var offset = 2
            while offset + 9 < data.count {
                guard data[data.startIndex + offset] == 0xFF else { return nil }
                let marker = data[data.startIndex + offset + 1]
                let length = Int(data[data.startIndex + offset + 2]) << 8 | Int(data[data.startIndex + offset + 3])
                if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC {
                    let height = Int(data[data.startIndex + offset + 5]) << 8 | Int(data[data.startIndex + offset + 6])
                    let width = Int(data[data.startIndex + offset + 7]) << 8 | Int(data[data.startIndex + offset + 8])
                    return (width, height, 24)
                }
                offset += 2 + length
            }
        }
        return nil
    }
}

extension Data {
    func readLEUInt32(at offset: Int) -> UInt32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian
    }

    func readBEUInt32(at offset: Int) -> UInt32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.bigEndian
    }

    mutating func appendLEUInt32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendBEUInt32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
