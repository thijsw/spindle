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
    /// CRC32 with CTDB skip semantics (first track: 2940 leading samples
    /// skipped; last track: 2940 + disc-length remainder trailing samples).
    public let ctdbCRC32: UInt32

    public init(crc32: UInt32, accurateRipV1: UInt32, accurateRipV2: UInt32, ctdbCRC32: UInt32) {
        self.crc32 = crc32
        self.accurateRipV1 = accurateRipV1
        self.accurateRipV2 = accurateRipV2
        self.ctdbCRC32 = ctdbCRC32
    }
}

/// CRC32 over only the bytes inside `coveredBytes` of a longer stream.
public struct RangeGatedCRC32: Sendable {
    private var crc = CRC32()
    private var position = 0
    private let coveredBytes: Range<Int>

    public init(coveredBytes: Range<Int>) {
        self.coveredBytes = coveredBytes
    }

    public mutating func update(_ data: Data) {
        let chunk = position ..< position + data.count
        position = chunk.upperBound
        let overlap = chunk.clamped(to: coveredBytes)
        guard !overlap.isEmpty else { return }
        let lower = data.startIndex + (overlap.lowerBound - chunk.lowerBound)
        crc.update(data.subdata(in: lower ..< lower + overlap.count))
    }

    public var value: UInt32 { crc.value }
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
    private var ctdb: RangeGatedCRC32
    private var arV1: UInt32 = 0
    private var arV2: UInt32 = 0
    private var sampleIndex = 0 // 0-based, in 4-byte sample frames
    private let skippedLeadingSamples: Int
    private let firstExcludedTrailingSample: Int
    private var pending = Data() // carries partial sample frames between updates

    public init(
        totalSamples: Int,
        isFirstTrack: Bool,
        isLastTrack: Bool,
        ctdbLeadingSkip: Int = 0,
        ctdbTrailingSkip: Int = 0
    ) {
        self.skippedLeadingSamples = isFirstTrack ? 5 * 588 - 1 : 0
        self.firstExcludedTrailingSample = totalSamples - (isLastTrack ? 5 * 588 : 0)
        self.ctdb = RangeGatedCRC32(
            coveredBytes: ctdbLeadingSkip * 4 ..< (totalSamples - ctdbTrailingSkip) * 4
        )
    }

    public mutating func update(_ data: Data) {
        crc.update(data)
        ctdb.update(data)

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
        TrackChecksums(crc32: crc.value, accurateRipV1: arV1, accurateRipV2: arV2, ctdbCRC32: ctdb.value)
    }
}
