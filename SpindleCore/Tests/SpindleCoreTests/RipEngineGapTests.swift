import DiscDrive
import Foundation
@testable import RipEngine
import Testing

/// Coverage the original suite lacked: the whole-disc CTDB CRC, offsets
/// larger than a sector in every engine mode, sector-buffer layout,
/// cancellation and the position/window helpers.
@Suite struct RipEngineGapTests {
    let leadOut = 400
    var toc: TOC { makeTOC(trackSectors: [0 ..< 150, 150 ..< 400], leadOut: leadOut) }

    @Test func wholeDiscCTDBCRCCoversTheCalibratedWindow() async throws {
        try await withTempDir { dir in
            let result = try await DiscRipper(device: MockCDDevice(leadOut: leadOut), configuration: RipConfiguration(mode: .burst))
                .rip(toc: toc, to: dir)
            let window = try #require(CTDBWindow.discWindow(for: toc))
            let expected = CRC32.checksum(canonicalBytes(window.lowerBound * 4 ..< window.upperBound * 4))
            #expect(result.isCompleteDisc)
            #expect(result.ctdbDiscCRC32 == expected)
            #expect(window == 5880 ..< (leadOut * 588 - (5880 + (leadOut * 588) % 5880)))
        }
    }

    @Test(arguments: [667, -1164]) func offsetsLargerThanASectorAreExactInBurstMode(offset: Int) async throws {
        try await withTempDir { dir in
            let config = RipConfiguration(mode: .burst, sampleOffset: offset, chunkSectors: 25)
            let tracks = try await DiscRipper(device: MockCDDevice(leadOut: leadOut), configuration: config)
                .rip(toc: toc, to: dir).tracks
            #expect(wavData(tracks[0].wavURL) == expectedAudio(trackSectors: 0 ..< 150, sampleOffset: offset, leadOut: leadOut))
            #expect(wavData(tracks[1].wavURL) == expectedAudio(trackSectors: 150 ..< 400, sampleOffset: offset, leadOut: leadOut))
        }
    }

    /// Compare mode settles a *corrected* sector window, which with an
    /// offset spans two device sectors — the case settleWindow exists for.
    @Test func offsetInCompareModeSettlesStraddlingWindows() async throws {
        try await withTempDir { dir in
            let device = MockCDDevice(leadOut: leadOut, supportsC2: false, flaky: [
                77: .init(badReads: 3, flagsC2: false),
                149: .init(badReads: 2, flagsC2: false), // at the track boundary
            ])
            let config = RipConfiguration(mode: .secure(maxRetries: 16, agreeingPasses: 2), sampleOffset: 102, chunkSectors: 25)
            let tracks = try await DiscRipper(device: device, configuration: config).rip(toc: toc, to: dir).tracks
            #expect(!tracks[0].usedC2)
            #expect(wavData(tracks[0].wavURL) == expectedAudio(trackSectors: 0 ..< 150, sampleOffset: 102, leadOut: leadOut))
            #expect(wavData(tracks[1].wavURL) == expectedAudio(trackSectors: 150 ..< 400, sampleOffset: 102, leadOut: leadOut))
            #expect(tracks.allSatisfy { $0.unrecoverableSectors.isEmpty })
        }
    }

    @Test func offsetInC2ModeIsExact() async throws {
        try await withTempDir { dir in
            let device = MockCDDevice(leadOut: leadOut, flaky: [40: .init(badReads: 3, flagsC2: true)])
            let config = RipConfiguration(mode: .secure(maxRetries: 16, agreeingPasses: 2), sampleOffset: -30, chunkSectors: 25)
            let tracks = try await DiscRipper(device: device, configuration: config).rip(toc: toc, to: dir).tracks
            #expect(tracks[0].usedC2)
            #expect(wavData(tracks[0].wavURL) == expectedAudio(trackSectors: 0 ..< 150, sampleOffset: -30, leadOut: leadOut))
            #expect(wavData(tracks[1].wavURL) == expectedAudio(trackSectors: 150 ..< 400, sampleOffset: -30, leadOut: leadOut))
        }
    }

    @Test func sectorBufferLayoutWithAndWithoutAudio() {
        // Two sectors: audio + C2 (sector 1 flagged), then C2-only.
        var withAudio = Data(count: 2 * (2352 + 294))
        withAudio[2352 + 294 + 2352 + 10] = 0x01
        let buffer = SectorBuffer(sectorCount: 2, areas: [.user, .errorFlags], data: withAudio)
        #expect(buffer.c2FlaggedSectors() == [1])
        #expect(!buffer.hasC2Error(sector: 0) && buffer.hasC2Error(sector: 1))
        #expect(buffer.audio(sector: 1).count == 2352 && buffer.allAudio().count == 2 * 2352)

        var flagsOnly = Data(count: 2 * 294)
        flagsOnly[3] = 0x80
        let c2 = SectorBuffer(sectorCount: 2, areas: .errorFlags, data: flagsOnly)
        #expect(c2.c2FlaggedSectors() == [0])

        let plain = SectorBuffer(sectorCount: 1, areas: .user, data: Data(count: 2352))
        #expect(plain.c2FlaggedSectors().isEmpty && !plain.hasC2Error(sector: 0))
    }

    @Test func cancellationStopsTheRipWithCancellationError() async throws {
        try await withTempDir { dir in
            // Every read stalls briefly so the cancel lands mid-track.
            let device = MockCDDevice(leadOut: leadOut, slowSectors: Set(0 ..< 400), slowReadDelay: .milliseconds(30))
            let rip = Task {
                try await DiscRipper(device: device, configuration: RipConfiguration(mode: .burst, chunkSectors: 10))
                    .rip(toc: toc, to: dir)
            }
            try await Task.sleep(for: .milliseconds(120))
            rip.cancel()
            do {
                _ = try await rip.value
                Issue.record("rip should have been cancelled")
            } catch is CancellationError {
                // expected
            }
        }
    }

    @Test func trackPositionsAndWindowsFollowTheTOC() {
        let windows = CTDBWindow.trackWindows(for: toc)
        #expect(windows.map(\.track.number) == [1, 2])
        #expect(windows[0].samples == 5880 ..< 150 * 588)
        #expect(windows[1].samples.lowerBound == 150 * 588)
        #expect(windows[1].samples.upperBound == leadOut * 588 - CTDBWindow.suffix(totalSamples: leadOut * 588))

        let first = TrackPosition(of: toc.tracks[0], in: toc)
        let last = TrackPosition(of: toc.tracks[1], in: toc)
        #expect(first.isFirst && !first.isLast && first.discTotalSamples == leadOut * 588)
        #expect(!last.isFirst && last.isLast)

        // Enhanced CD: a data session after the audio doesn't extend the audio area.
        let enhanced = TOC(
            tracks: [
                TOCTrack(number: 1, session: 1, startLBA: 0, isAudio: true, hasPreEmphasis: false),
                TOCTrack(number: 2, session: 2, startLBA: 20000, isAudio: false, hasPreEmphasis: false),
            ],
            sessionLeadOuts: [1: 8000, 2: 30000], firstSession: 1, lastSession: 2
        )
        #expect(enhanced.audioLeadOutLBA == 8000)
        #expect(CTDBWindow.totalSamples(of: enhanced) == 8000 * 588)
    }

    @Test func flooredDivisionRoundsTowardNegativeInfinity() {
        #expect(7.flooredDivision(by: 2352) == 0)
        #expect((-1).flooredDivision(by: 2352) == -1)
        #expect((-2352).flooredDivision(by: 2352) == -1)
        #expect((-2353).flooredDivision(by: 2352) == -2)
        #expect(2352.flooredDivision(by: 2352) == 1)
    }
}
