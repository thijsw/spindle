import DiscDrive
import Foundation
import Metadata

@MainActor
func discIDTests() {
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

    Harness.suite("DiscID") {
        Harness.expect(
            reference.musicBrainzDiscID == "xUp1F2NkfP8s8jaeFn_Av3jNEI4-",
            "MusicBrainz DiscID matches libdiscid vector"
        )
        Harness.expect(
            reference.freeDBDiscID == "370fce16",
            "FreeDB ID matches libdiscid vector"
        )
        Harness.expect(
            reference.musicBrainzTOCString == "1 22 303602 150 9700 25887 39297 53795 63735 77517 94877 107270 123552 135522 148422 161197 174790 192022 205545 218010 228700 239590 255470 266932 288750",
            "TOC string matches libdiscid vector"
        )

        let tiny = DiscTOC(firstTrack: 1, lastTrack: 1, leadOutOffset: 5000, trackOffsets: [150])
        Harness.expect(tiny.musicBrainzDiscID.count == 28, "DiscID is always 28 characters")

        // Same reference disc expressed as a parsed TOC with 0-based LBAs.
        let tracks = reference.trackOffsets.enumerated().map { index, offset in
            TOCTrack(number: index + 1, session: 1, startLBA: offset - 150, isAudio: true, hasPreEmphasis: false)
        }
        let toc = TOC(
            tracks: tracks,
            sessionLeadOuts: [1: reference.leadOutOffset - 150],
            firstSession: 1,
            lastSession: 1
        )
        Harness.expect(
            DiscTOC(toc: toc)?.musicBrainzDiscID == "xUp1F2NkfP8s8jaeFn_Av3jNEI4-",
            "derives correctly from parsed TOC (LBA + 150 conversion)"
        )

        // Enhanced CD: audio in session 1, data track in session 2.
        var extraTracks = (1...3).map { n in
            TOCTrack(number: n, session: 1, startLBA: (n - 1) * 10000, isAudio: true, hasPreEmphasis: false)
        }
        extraTracks.append(TOCTrack(number: 4, session: 2, startLBA: 45000, isAudio: false, hasPreEmphasis: false))
        let enhanced = TOC(
            tracks: extraTracks,
            sessionLeadOuts: [1: 33000, 2: 60000],
            firstSession: 1,
            lastSession: 2
        )
        let derived = DiscTOC(toc: enhanced)
        Harness.expect(derived?.lastTrack == 3, "enhanced CD: data track excluded")
        Harness.expect(
            derived?.leadOutOffset == 45000 + 150 - 11400,
            "enhanced CD: lead-out is data track start - 11400"
        )

        let dataOnly = TOC(
            tracks: [TOCTrack(number: 1, session: 1, startLBA: 0, isAudio: false, hasPreEmphasis: false)],
            sessionLeadOuts: [1: 1000],
            firstSession: 1,
            lastSession: 1
        )
        Harness.expect(DiscTOC(toc: dataOnly) == nil, "disc with no audio tracks yields nil")
    }
}
