import Foundation

/// Standard CRC-32 (zlib polynomial), used as Spindle's rip-stability checksum
/// and by the CTDB/AccurateRip ecosystem.
public struct CRC32: Sendable {
    private static let table: [UInt32] = (0 ..< 256).map { n in
        var c = UInt32(n)
        for _ in 0 ..< 8 {
            c = (c & 1 != 0) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private var state: UInt32 = 0xFFFF_FFFF

    public init() {}

    public mutating func update(_ data: Data) {
        for byte in data {
            state = Self.table[Int((state ^ UInt32(byte)) & 0xFF)] ^ (state >> 8)
        }
    }

    public var value: UInt32 { state ^ 0xFFFF_FFFF }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc = CRC32()
        crc.update(data)
        return crc.value
    }
}

public struct TrackChecksums: Sendable, Hashable, Codable {
    public let crc32: UInt32
    public let accurateRipV1: UInt32
    public let accurateRipV2: UInt32
}

/// Streaming checksum accumulator for one track's audio (16-bit stereo LE).
///
/// AccurateRip semantics: the multiplier is the 1-based 4-byte sample index
/// from the track start; the first track of a disc excludes the first
/// 5 × 588 − 1 samples and the last track excludes the final 5 × 588 samples
/// (the database stores checksums computed this way to tolerate offset
/// differences at the disc edges).
public struct ChecksumAccumulator: Sendable {
    private var crc = CRC32()
    private var arV1: UInt32 = 0
    private var arV2: UInt32 = 0
    private var sampleIndex = 0 // 0-based, in 4-byte sample frames
    private let skippedLeadingSamples: Int
    private let firstExcludedTrailingSample: Int
    private var pending = Data() // carries partial sample frames between updates

    public init(totalSamples: Int, isFirstTrack: Bool, isLastTrack: Bool) {
        self.skippedLeadingSamples = isFirstTrack ? 5 * 588 - 1 : 0
        self.firstExcludedTrailingSample = totalSamples - (isLastTrack ? 5 * 588 : 0)
    }

    public mutating func update(_ data: Data) {
        crc.update(data)

        var buffer: Data
        if pending.isEmpty {
            buffer = data
        } else {
            buffer = pending
            buffer.append(data)
        }
        let usableBytes = buffer.count - buffer.count % 4
        pending = buffer.suffix(buffer.count - usableBytes)

        buffer.prefix(usableBytes).withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for frame in 0 ..< usableBytes / 4 {
                let value = raw.loadUnaligned(fromByteOffset: frame * 4, as: UInt32.self).littleEndian
                let index = sampleIndex + frame
                guard index >= skippedLeadingSamples, index < firstExcludedTrailingSample else { continue }
                let multiplier = UInt64(index + 1)
                let product = multiplier * UInt64(value)
                arV1 = arV1 &+ UInt32(truncatingIfNeeded: product)
                arV2 = arV2 &+ UInt32(truncatingIfNeeded: product) &+ UInt32(truncatingIfNeeded: product >> 32)
            }
        }
        sampleIndex += usableBytes / 4
    }

    public func finalize() -> TrackChecksums {
        TrackChecksums(crc32: crc.value, accurateRipV1: arV1, accurateRipV2: arV2)
    }
}
