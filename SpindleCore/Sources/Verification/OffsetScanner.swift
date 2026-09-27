import DiscDrive
import Foundation
import RipEngine

public enum OffsetScanError: Error, CustomStringConvertible, Sendable {
    case truncatedWAV(String)

    public var description: String {
        switch self {
        case .truncatedWAV(let name): "Staged WAV \(name) is too small to contain audio"
        }
    }
}

/// Determines a drive's read offset empirically: given a rip made at offset
/// 0, recompute every track's CTDB checksum as if the rip had been made at
/// each candidate offset, and find the shift at which the database agrees.
///
/// This mirrors CUETools' offsetted TrackCRC: candidate `k` reads our data
/// over the canonical track windows shifted by `+k` samples (zero-padded at
/// the disc edges, like the rip engine itself would have).
public enum OffsetScanner {
    /// Common AccurateRip drive offsets, by rough frequency of occurrence.
    public static let commonOffsets: [Int] = [
        0, 6, 102, 667, 48, 12, 30, 91, 96, 97, 108, 120, 18, 24, 145, 355,
        564, 582, 685, 691, 704, 738, 1194,
        -6, -12, -24, -91, -102, -445, -582, -1164,
    ]

    public struct Candidate: Sendable {
        public let offset: Int
        /// Tracks with at least one database entry agreeing at this offset.
        public let matchedTracks: Int
        public let totalTracks: Int
        /// Summed confidence over all matching (track, entry) pairs.
        public let confidence: Int
        public let trackVerdicts: [Int: TrackVerdict]

        public var isFullMatch: Bool { matchedTracks == totalTracks }
    }

    /// - Parameters:
    ///   - wavURLs: staging WAVs of the rip (offset 0), in disc order.
    ///   - toc: the disc's table of contents.
    ///   - entries: CTDB entries for this disc.
    ///   - candidates: offsets to test (defaults to the common set).
    /// - Returns: candidates sorted best-first (most matched tracks, then
    ///   highest confidence, then smallest absolute offset).
    public static func scan(
        wavURLs: [URL],
        toc: TOC,
        entries: [CTDBEntry],
        candidates: [Int] = commonOffsets
    ) throws -> [Candidate] {
        let audioTracks = toc.audioTracks
        guard wavURLs.count == audioTracks.count, !entries.isEmpty else { return [] }

        // Memory-map the staging WAVs and expose them as one logical stream
        // of disc audio starting at the first audio track.
        let pcm: [Data] = try wavURLs.map { url in
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            guard data.count > WAVWriter.headerSize else {
                throw OffsetScanError.truncatedWAV(url.lastPathComponent)
            }
            return data.dropFirst(WAVWriter.headerSize)
        }
        let stream = ConcatenatedBytes(chunks: pcm)

        let firstSample = audioTracks[0].startLBA * SectorAreas.samplesPerSector
        let totalSamples = CTDBWindow.totalSamples(of: toc)
        // Absolute sample windows of each track's CTDB checksum at offset 0.
        let windows = CTDBWindow.trackWindows(for: toc)

        var results: [Candidate] = []
        for offset in candidates {
            var verdicts: [Int: TrackVerdict] = [:]
            var matched = 0
            var confidence = 0

            for (index, window) in windows.enumerated() {
                let crc = streamCRC(
                    stream: stream,
                    sampleRange: (window.samples.lowerBound + offset) ..< (window.samples.upperBound + offset),
                    firstSample: firstSample,
                    totalSamples: totalSamples
                )
                let verdict = CTDBVerifier.verdict(trackIndex: index, crc: crc, entries: entries)
                if case .accuratelyRipped(let trackConfidence) = verdict {
                    matched += 1
                    confidence += trackConfidence
                }
                verdicts[window.track.number] = verdict
            }

            results.append(Candidate(
                offset: offset,
                matchedTracks: matched,
                totalTracks: windows.count,
                confidence: confidence,
                trackVerdicts: verdicts
            ))
        }

        return results.sorted {
            ($0.matchedTracks, $0.confidence, -abs($0.offset))
                > ($1.matchedTracks, $1.confidence, -abs($1.offset))
        }
    }

    /// CRC32 of the stream over an absolute sample range, zero-padding
    /// samples outside the readable audio area — matching what the rip
    /// engine would have produced at that offset.
    private static func streamCRC(
        stream: ConcatenatedBytes,
        sampleRange: Range<Int>,
        firstSample: Int,
        totalSamples: Int
    ) -> UInt32 {
        var crc = CRC32()
        let readable = max(sampleRange.lowerBound, firstSample) ..< min(sampleRange.upperBound, totalSamples)

        if readable.lowerBound > sampleRange.lowerBound {
            crc.update(Data(count: (readable.lowerBound - sampleRange.lowerBound) * 4))
        }
        if !readable.isEmpty {
            var position = (readable.lowerBound - firstSample) * 4
            let end = (readable.upperBound - firstSample) * 4
            while position < end {
                let chunk = min(4 << 20, end - position)
                crc.update(stream.bytes(in: position ..< position + chunk))
                position += chunk
            }
        }
        if sampleRange.upperBound > readable.upperBound {
            crc.update(Data(count: (sampleRange.upperBound - max(readable.upperBound, sampleRange.lowerBound)) * 4))
        }
        return crc.value
    }
}

/// Read-only random access over several Data chunks as one logical stream.
struct ConcatenatedBytes {
    private let chunks: [Data]
    private let offsets: [Int] // start offset of each chunk
    let count: Int

    init(chunks: [Data]) {
        self.chunks = chunks
        var offsets: [Int] = []
        var total = 0
        for chunk in chunks {
            offsets.append(total)
            total += chunk.count
        }
        self.offsets = offsets
        self.count = total
    }

    func bytes(in range: Range<Int>) -> Data {
        let clamped = range.clamped(to: 0 ..< count)
        guard !clamped.isEmpty else { return Data() }

        var result = Data(capacity: clamped.count)
        // Binary search for the first chunk containing the range start.
        var index = offsets.lastIndexBefore(orAt: clamped.lowerBound)
        var position = clamped.lowerBound
        while position < clamped.upperBound, index < chunks.count {
            let chunk = chunks[index]
            let chunkStart = offsets[index]
            let local = (position - chunkStart) ..< min(chunk.count, clamped.upperBound - chunkStart)
            result.append(chunk.subdata(in: chunk.startIndex + local.lowerBound ..< chunk.startIndex + local.upperBound))
            position = chunkStart + local.upperBound
            index += 1
        }
        return result
    }
}

private extension [Int] {
    /// Index of the last element ≤ value (assumes sorted ascending, non-empty).
    func lastIndexBefore(orAt value: Int) -> Int {
        var low = 0, high = count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if self[mid] <= value { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
