import DiscDrive
import Foundation
import Metadata
import RipEngine
import SpindleCore
import Testing
import Verification

@Suite struct RipLogTests {
    // Two audio tracks, the second with pre-emphasis; track 3 failed.
    private var toc: TOC {
        TOC(
            tracks: [
                TOCTrack(number: 1, session: 1, startLBA: 0, isAudio: true, hasPreEmphasis: false),
                TOCTrack(number: 2, session: 1, startLBA: 15000, isAudio: true, hasPreEmphasis: true),
                TOCTrack(number: 3, session: 1, startLBA: 30000, isAudio: true, hasPreEmphasis: false),
            ],
            sessionLeadOuts: [1: 45000],
            firstSession: 1,
            lastSession: 1
        )
    }

    private func ripped(_ number: Int, rereads: Int = 0, unrecoverable: [Int] = []) -> RippedTrack {
        RippedTrack(
            trackNumber: number,
            wavURL: URL(fileURLWithPath: "/tmp/track\(number).wav"),
            checksums: TrackChecksums(
                crc32: 0xAB12_CD34,
                accurateRipV1: 0x1111_1111,
                accurateRipV2: 0x2222_2222,
                ctdbCRC32: 0x3333_3333
            ),
            rereads: rereads,
            unrecoverableSectors: unrecoverable,
            usedC2: false
        )
    }

    private var outcome: VerifiedRipper.Outcome {
        VerifiedRipper.Outcome(
            tracks: [ripped(1), ripped(2, rereads: 12, unrecoverable: [15100])],
            verification: VerificationResult(
                entries: [CTDBEntry(id: "742", confidence: 34230, discCRC32: 0, trackCRC32s: [], hasParity: false)],
                trackVerdicts: [1: .accuratelyRipped(confidence: 34230), 2: .differs(bestConfidence: 12)],
                discMatch: CTDBEntry(id: "742", confidence: 34230, discCRC32: 0, trackCRC32s: [], hasParity: false)
            ),
            reRippedTracks: [2],
            strategy: "Secure re-rip of 1 track(s) with read errors",
            c2Unreliable: true,
            failedTracks: [3]
        )
    }

    private var album: ResolvedAlbum {
        var album = makeTestAlbum()
        album.tracks.append(ResolvedTrack(position: 3, title: "Third Song", artist: "Test Artist"))
        return album
    }

    @Test func logRecordsProvenanceVerdictsAndWarnings() {
        let log = RipLog(
            ripDate: Date(timeIntervalSince1970: 1_780_000_000),
            appVersion: "0.1-test",
            drive: DriveIdentity(vendor: "HL-DT-ST", product: "DVDRW GX50N", revision: "RB00"),
            configuration: RipConfiguration(sampleOffset: 6),
            toc: toc,
            discTOC: nil,
            album: album,
            outcome: outcome,
            ripDuration: .seconds(318)
        ).render()

        #expect(log.contains("Spindle 0.1-test — rip log"))
        #expect(log.contains("HL-DT-ST DVDRW GX50N [RB00]"))
        #expect(log.contains("Read offset  : +6 samples"))
        #expect(log.contains("Rip time     : 5:18"))
        #expect(log.contains("Album        : Test Artist — Test Album"))
        #expect(log.contains("01  CRC32 AB12CD34  ARv1 11111111  ARv2 22222222  CTDB 33333333  ✓ verified (confidence 34230)"))
        #expect(log.contains("✗ differs from database (best confidence 12)"))
        #expect(log.contains("secure re-rip, 12 re-reads, 1 unrecoverable sectors (zero-filled)"))
        #expect(log.contains("03  NOT RIPPED — unreadable within the time limit"))
        #expect(log.contains("Disc match   : CTDB entry 742 (confidence 34230)"))
        #expect(log.contains("track(s) 2 carry pre-emphasis"))
        #expect(log.contains("Warning: the drive's C2 error reporting was caught lying"))
    }

    @Test func cueSheetListsTracksWithFlagsAndQuotes() {
        var quoted = album
        quoted.tracks[0].title = #"A "Quoted" Song"#
        let cue = CueSheet.render(
            album: quoted,
            toc: toc,
            discTOC: nil,
            fileNames: [
                1: "01 - First Song.flac",
                2: "02 - Second Song.flac",
            ],
            comment: "Spindle 0.1-test"
        )

        #expect(cue.contains(#"REM COMMENT "Spindle 0.1-test""#))
        #expect(cue.contains("REM DATE 1997"))
        #expect(cue.contains(#"PERFORMER "Test Artist""#))
        #expect(cue.contains(#"FILE "01 - First Song.flac" WAVE"#))
        #expect(cue.contains("  TRACK 01 AUDIO"))
        #expect(cue.contains(#"    TITLE "A 'Quoted' Song""#), "double quotes neutralized")
        #expect(cue.contains("    ISRC NLA319700019"))
        #expect(cue.contains("FLAGS PRE"), "pre-emphasis carried from the TOC")
        // Track 3 has no file (failed rip): no entry at all.
        #expect(!cue.contains("TRACK 03"))

        // FLAGS PRE belongs to track 2 only.
        let track1Block = cue.range(of: "TRACK 01")!.lowerBound ..< cue.range(of: "TRACK 02")!.lowerBound
        #expect(!cue[track1Block].contains("FLAGS PRE"))
    }
}
