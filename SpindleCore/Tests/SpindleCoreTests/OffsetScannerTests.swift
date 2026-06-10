import DiscDrive
import Foundation
import RipEngine
import Testing
import Verification

@Suite struct OffsetScannerTests {
    /// Canonical disc audio byte at an absolute byte position.
    private func canonical(_ position: Int) -> UInt8 {
        MockCDDevice.canonicalByte(at: position)
    }

    /// Simulates a drive whose correction is `trueOffset`: a rip made at
    /// offset 0 contains, at stream sample p, the canonical sample p − d
    /// (zeros outside the disc).
    @Test func findsTheTrueOffsetFromAnOffsetZeroRip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let trueOffset = 6
        let leadOut = 300 // sectors; totalSamples = 176400 (divisible by 2940)
        let trackSectors: [Range<Int>] = [0 ..< 120, 120 ..< 300]
        let toc = TOC(
            tracks: trackSectors.enumerated().map { i, range in
                TOCTrack(number: i + 1, session: 1, startLBA: range.lowerBound, isAudio: true, hasPreEmphasis: false)
            },
            sessionLeadOuts: [1: leadOut],
            firstSession: 1,
            lastSession: 1
        )

        // Write the simulated rip WAVs.
        let discBytes = 0 ..< leadOut * 2352
        var wavURLs: [URL] = []
        for (index, sectors) in trackSectors.enumerated() {
            let url = dir.appendingPathComponent(String(format: "track%02d.wav", index + 1))
            let writer = try WAVWriter(url: url)
            let range = sectors.lowerBound * 2352 ..< sectors.upperBound * 2352
            try writer.append(Data(range.map { position in
                let source = position - trueOffset * 4
                return discBytes.contains(source) ? canonical(source) : 0
            }))
            try writer.finish()
            wavURLs.append(url)
        }

        // Database entries carry CRCs of the canonical (corrected) audio.
        let totalSamples = leadOut * 588
        let prefix = 2940
        let suffix = 2940 + totalSamples % 2940
        let windows = [
            prefix * 4 ..< 120 * 2352, // track 1 (CTDB skip applied)
            120 * 2352 ..< (totalSamples - suffix) * 4, // track 2 (suffix applied)
        ]
        let trackCRCs = windows.map { window in
            CRC32.checksum(Data(window.map(canonical)))
        }
        let entry = CTDBEntry(
            id: "1", confidence: 50, discCRC32: 0,
            trackCRC32s: trackCRCs, stride: 5880, hasParity: false, tocString: ""
        )

        let candidates = try OffsetScanner.scan(
            wavURLs: wavURLs,
            toc: toc,
            entries: [entry],
            candidates: [0, -6, 6, 102, 667]
        )

        let best = try #require(candidates.first)
        #expect(best.offset == trueOffset, "scanner recovers the simulated +6 offset")
        #expect(best.isFullMatch)
        #expect(best.confidence == 100, "both tracks matched at confidence 50")

        // The wrong candidates must not fully match.
        let fullMatches = candidates.filter(\.isFullMatch)
        #expect(fullMatches.count == 1, "exactly one candidate matches everything")
    }
}
