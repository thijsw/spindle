import DiscDrive
import Metadata
import Testing

@Suite struct DiscIDTests {
    // Reference TOC from libdiscid's test suite (test_put.c).
    let reference = DiscTOC(
        firstTrack: 1,
        lastTrack: 22,
        leadOutOffset: 303602,
        trackOffsets: [
            150, 9700, 25887, 39297, 53795, 63735, 77517, 94877, 107270,
            123552, 135522, 148422, 161197, 174790, 192022, 205545,
            218010, 228700, 239590, 255470, 266932, 288750,
        ]
    )

    @Test func musicBrainzDiscIDMatchesLibdiscid() {
        #expect(reference.musicBrainzDiscID == "xUp1F2NkfP8s8jaeFn_Av3jNEI4-")
    }

    @Test func freeDBIDMatchesLibdiscid() {
        #expect(reference.freeDBDiscID == "370fce16")
    }

    @Test func tocStringMatchesLibdiscid() {
        #expect(reference.musicBrainzTOCString == "1 22 303602 150 9700 25887 39297 53795 63735 77517 94877 107270 123552 135522 148422 161197 174790 192022 205545 218010 228700 239590 255470 266932 288750")
    }

    @Test func discIDIsAlways28Characters() {
        let tiny = DiscTOC(firstTrack: 1, lastTrack: 1, leadOutOffset: 5000, trackOffsets: [150])
        #expect(tiny.musicBrainzDiscID.count == 28)
        #expect(reference.musicBrainzDiscID.count == 28)
    }

    @Test func derivesFromParsedTOCWithLBAConversion() {
        // Same disc expressed as a parsed TOC with 0-based LBAs.
        let tracks = reference.trackOffsets.enumerated().map { index, offset in
            TOCTrack(number: index + 1, session: 1, startLBA: offset - 150, isAudio: true, hasPreEmphasis: false)
        }
        let toc = TOC(
            tracks: tracks,
            sessionLeadOuts: [1: reference.leadOutOffset - 150],
            firstSession: 1,
            lastSession: 1
        )
        #expect(DiscTOC(toc: toc)?.musicBrainzDiscID == "xUp1F2NkfP8s8jaeFn_Av3jNEI4-")
    }

    @Test func enhancedCDUsesDataTrackMinus11400AsLeadOut() {
        // Audio session 1 + data track in session 2 (CD-Extra layout).
        var tracks = (1...3).map { n in
            TOCTrack(number: n, session: 1, startLBA: (n - 1) * 10000, isAudio: true, hasPreEmphasis: false)
        }
        tracks.append(TOCTrack(number: 4, session: 2, startLBA: 45000, isAudio: false, hasPreEmphasis: false))
        let toc = TOC(
            tracks: tracks,
            sessionLeadOuts: [1: 33000, 2: 60000],
            firstSession: 1,
            lastSession: 2
        )
        let derived = DiscTOC(toc: toc)
        #expect(derived?.lastTrack == 3)
        #expect(derived?.leadOutOffset == 45000 + 150 - 11400)
        #expect(derived?.trackOffsets.count == 3)
    }

    @Test func discWithNoAudioTracksYieldsNil() {
        let toc = TOC(
            tracks: [TOCTrack(number: 1, session: 1, startLBA: 0, isAudio: false, hasPreEmphasis: false)],
            sessionLeadOuts: [1: 1000],
            firstSession: 1,
            lastSession: 1
        )
        #expect(DiscTOC(toc: toc) == nil)
    }
}
