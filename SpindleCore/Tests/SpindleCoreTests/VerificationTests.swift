import DiscDrive
import Foundation
import RipEngine
import Testing
import Verification

// Trimmed real response from db.cue.tools for the Hello Nasty TOC.
private let ctdbXML = """
<ctdb xmlns="http://db.cuetools.net/ns/mmd-1.0#" xmlns:ext="http://db.cuetools.net/ns/ext-1.0#">
 <entry confidence="2025" crc32="36238217" hasparity="http://p.cuetools.net/14172" id="14172" npar="16" stride="5880" \
syndrome="YHfk4mYUpiyYXFjl7BRapqh33hnkiYxVGGSLEc7Eem0=" toc="0:9550:25737:39147" trackcrcs="de926818 c1749980 c7ede100 49e963ff" />
 <entry confidence="28" crc32="917103eb" id="248696" npar="8" stride="5880" \
toc="0:9550:25737:39147" trackcrcs="6c249dd1 d18c2d34 c69d5d72 4902c585" />
</ctdb>
"""

@Suite struct CTDBClientTests {
    @Test func parsesEntries() throws {
        let entries = try CTDBClient.parse(xml: Data(ctdbXML.utf8))
        #expect(entries.count == 2)
        #expect(entries[0].confidence == 2025)
        #expect(entries[0].discCRC32 == 0x3623_8217)
        #expect(entries[0].trackCRC32s == [0xDE92_6818, 0xC174_9980, 0xC7ED_E100, 0x49E9_63FF])
        #expect(entries[0].hasParity && !entries[1].hasParity)
    }

    @Test func tocParameterMarksDataTracksAndAppendsLeadOut() {
        let toc = TOC(
            tracks: [
                TOCTrack(number: 1, session: 1, startLBA: 0, isAudio: true, hasPreEmphasis: false),
                TOCTrack(number: 2, session: 1, startLBA: 9550, isAudio: true, hasPreEmphasis: false),
                TOCTrack(number: 3, session: 2, startLBA: 25737, isAudio: false, hasPreEmphasis: false),
            ],
            sessionLeadOuts: [1: 20000, 2: 39147],
            firstSession: 1,
            lastSession: 2
        )
        #expect(CTDBClient.tocParameter(for: toc) == "0:9550:-25737:39147")
    }
}

@Suite struct CTDBVerifierTests {
    private func checksums(_ ctdb: UInt32) -> TrackChecksums {
        TrackChecksums(crc32: 0, accurateRipV1: 0, accurateRipV2: 0, ctdbCRC32: ctdb)
    }

    @Test func matchesTracksAcrossEntries() throws {
        let entries = try CTDBClient.parse(xml: Data(ctdbXML.utf8))
        let result = CTDBVerifier.match(
            entries: entries,
            audioTrackNumbers: [1, 2, 3, 4],
            trackChecksums: [
                1: checksums(0xDE92_6818), // matches entry 1
                2: checksums(0xD18C_2D34), // matches entry 2
                3: checksums(0xDEAD_BEEF), // matches nothing
                4: checksums(0x49E9_63FF), // matches entry 1
            ],
            ctdbDiscCRC32: 0x3623_8217
        )
        #expect(result.trackVerdicts[1] == .accuratelyRipped(confidence: 2025))
        #expect(result.trackVerdicts[2] == .accuratelyRipped(confidence: 28), "alternate pressing also verifies")
        #expect(result.trackVerdicts[3] == .differs(bestConfidence: 2025))
        #expect(result.trackVerdicts[4] == .accuratelyRipped(confidence: 2025))
        #expect(result.discMatch?.id == "14172")
    }

    @Test func unknownDiscIsNeutral() {
        let empty = CTDBVerifier.match(
            entries: [],
            audioTrackNumbers: [1, 2],
            trackChecksums: [:],
            ctdbDiscCRC32: nil
        )
        #expect(empty.trackVerdicts == [1: .notInDatabase, 2: .notInDatabase])
        #expect(empty.summary == "Not in CTDB")
    }
}

@Suite struct CTDBChecksumSemanticsTests {
    // Toy stream large enough that the covered window is non-empty.
    let totalSamples = 30 * 588
    var prefix: Int { 5880 }
    var suffix: Int { 5880 + totalSamples % 5880 }
    var covered: Range<Int> { prefix * 4 ..< (totalSamples - suffix) * 4 }

    var bytes: Data {
        var data = Data(count: totalSamples * 4)
        for i in 0 ..< data.count { data[i] = UInt8((i &* 7) & 0xFF) }
        return data
    }

    @Test func gatedCRCEqualsCRCOfCoveredSlice() {
        var gated = RangeGatedCRC32(coveredBytes: covered)
        gated.update(bytes)
        #expect(gated.value == CRC32.checksum(bytes.subdata(in: covered)))
    }

    @Test func bytesOutsideWindowAreIgnored() {
        var mutated = bytes
        mutated[0] = 0xFF
        mutated[mutated.count - 1] = 0xFF
        var gated = RangeGatedCRC32(coveredBytes: covered)
        gated.update(mutated)
        #expect(gated.value == CRC32.checksum(bytes.subdata(in: covered)))
    }

    @Test func bytesInsideWindowMatter() {
        var mutated = bytes
        mutated[prefix * 4 + 100] ^= 0x01
        var gated = RangeGatedCRC32(coveredBytes: covered)
        gated.update(mutated)
        #expect(gated.value != CRC32.checksum(bytes.subdata(in: covered)))
    }

    @Test func chunkedFeedingMatchesOneShot() {
        var gated = RangeGatedCRC32(coveredBytes: covered)
        var rest = bytes
        while !rest.isEmpty {
            let n = min(997, rest.count)
            gated.update(rest.prefix(n))
            rest = rest.dropFirst(n)
        }
        #expect(gated.value == CRC32.checksum(bytes.subdata(in: covered)))
    }
}
