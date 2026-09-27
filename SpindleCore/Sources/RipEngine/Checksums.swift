import DiscDrive
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

/// The CTDB checksum window, calibrated against the live database (confidence
/// ~2600; verified 13/13 on real hardware). The first audio track skips one
/// full stride at the disc start; the last track stops one stride plus the
/// disc-length remainder before the lead-out. These are the numbers CLAUDE.md
/// warns must not be re-derived — the rip engine and the offset scanner both
/// read them from here so the two can never silently drift apart.
public enum CTDBWindow {
    /// CUETools' fixed CTDB stride, in samples.
    public static let stride = 5880
    /// Samples skipped at the very start of the disc (first audio track).
    public static var prefix: Int { stride }
    /// Samples excluded before the lead-out (last audio track), given the
    /// disc's total audio length in samples.
    public static func suffix(totalSamples: Int) -> Int {
        stride + totalSamples % stride
    }

    /// One audio track's checksum window in absolute disc samples.
    public struct TrackWindow: Sendable {
        public let track: TOCTrack
        public let samples: Range<Int>
    }

    /// The disc's total audio length in samples (up to the audio lead-out).
    public static func totalSamples(of toc: TOC) -> Int {
        toc.audioLeadOutLBA * SectorAreas.samplesPerSector
    }

    /// Per-track CTDB checksum windows: the first track starts one stride
    /// in, the last stops `suffix` before the lead-out, middle tracks are
    /// exact [start, nextStart). The rip engine's per-track accumulators,
    /// the disc-level CRC and the offset scanner all derive from this one
    /// function so they can never drift apart.
    public static func trackWindows(for toc: TOC) -> [TrackWindow] {
        let tracks = toc.audioTracks
        let total = totalSamples(of: toc)
        let perSector = SectorAreas.samplesPerSector
        return tracks.enumerated().map { index, track in
            let start = track.startLBA * perSector + (index == 0 ? prefix : 0)
            let end = index == tracks.count - 1
                ? total - suffix(totalSamples: total)
                : (track.startLBA + toc.lengthInSectors(of: track)) * perSector
            return TrackWindow(track: track, samples: start ..< end)
        }
    }

    /// The whole-disc CTDB window (first track's start to last track's end).
    public static func discWindow(for toc: TOC) -> Range<Int>? {
        let windows = trackWindows(for: toc)
        guard let first = windows.first, let last = windows.last else { return nil }
        return first.samples.lowerBound ..< last.samples.upperBound
    }
}

/// Where a track sits on the disc, which decides the AccurateRip and CTDB
/// edge exclusions of its checksums.
public struct TrackPosition: Sendable, Equatable {
    public let isFirst: Bool
    public let isLast: Bool
    /// Total audio samples of the disc (needed for the last track's CTDB
    /// trailing exclusion, which depends on the disc length).
    public let discTotalSamples: Int

    public init(isFirst: Bool, isLast: Bool, discTotalSamples: Int) {
        self.isFirst = isFirst
        self.isLast = isLast
        self.discTotalSamples = discTotalSamples
    }

    /// A track with other audio tracks on both sides: no edge exclusions.
    public static let middle = TrackPosition(isFirst: false, isLast: false, discTotalSamples: 0)

    /// Position of `track` among the disc's audio tracks.
    public init(of track: TOCTrack, in toc: TOC) {
        let audio = toc.audioTracks
        self.init(
            isFirst: track.number == audio.first?.number,
            isLast: track.number == audio.last?.number,
            discTotalSamples: CTDBWindow.totalSamples(of: toc)
        )
    }
}

public struct TrackChecksums: Sendable, Hashable, Codable {
    public let crc32: UInt32
    public let accurateRipV1: UInt32
    public let accurateRipV2: UInt32
    /// CRC32 with CTDB skip semantics: the first/last track exclude the
    /// `CTDBWindow` edge samples so the checksum tolerates disc-edge offset
    /// differences (see `CTDBWindow` for the calibrated stride/remainder).
    public let ctdbCRC32: UInt32

    public init(crc32: UInt32, accurateRipV1: UInt32, accurateRipV2: UInt32, ctdbCRC32: UInt32) {
        self.crc32 = crc32
        self.accurateRipV1 = accurateRipV1
        self.accurateRipV2 = accurateRipV2
        self.ctdbCRC32 = ctdbCRC32
    }
}

/// CRC32 over only the bytes inside `coveredBytes` of a longer stream.
struct RangeGatedCRC32: Sendable {
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

    /// - Parameters:
    ///   - totalSamples: the track's length in sample frames.
    ///   - position: first/last-track status, which sets both the
    ///     AccurateRip exclusions and the CTDB edge windows.
    public init(totalSamples: Int, position: TrackPosition) {
        let perSector = SectorAreas.samplesPerSector
        self.skippedLeadingSamples = position.isFirst ? 5 * perSector - 1 : 0
        self.firstExcludedTrailingSample = totalSamples - (position.isLast ? 5 * perSector : 0)
        let ctdbLeadingSkip = position.isFirst ? CTDBWindow.prefix : 0
        let ctdbTrailingSkip = position.isLast ? CTDBWindow.suffix(totalSamples: position.discTotalSamples) : 0
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
