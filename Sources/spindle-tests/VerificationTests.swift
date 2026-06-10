import DiscDrive
import Foundation
import RipEngine
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

@MainActor
func verificationTests() {
    Harness.suite("CTDB client") {
        guard let entries = try? CTDBClient.parse(xml: Data(ctdbXML.utf8)) else {
            Harness.expect(false, "CTDB XML parses")
            return
        }
        Harness.expect(entries.count == 2, "two entries parsed")
        Harness.expect(entries[0].confidence == 2025, "confidence parsed")
        Harness.expect(entries[0].discCRC32 == 0x3623_8217, "disc CRC parsed as hex")
        Harness.expect(entries[0].trackCRC32s == [0xDE92_6818, 0xC174_9980, 0xC7ED_E100, 0x49E9_63FF], "track CRCs parsed")
        Harness.expect(entries[0].hasParity && !entries[1].hasParity, "hasparity flag")

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
        Harness.expect(
            CTDBClient.tocParameter(for: toc) == "0:9550:-25737:39147",
            "TOC parameter marks data tracks and appends lead-out"
        )
    }

    Harness.suite("CTDB verifier matching") {
        let entries = (try? CTDBClient.parse(xml: Data(ctdbXML.utf8))) ?? []
        func checksums(_ ctdb: UInt32) -> TrackChecksums {
            var acc = ChecksumAccumulator(totalSamples: 0, isFirstTrack: false, isLastTrack: false)
            acc.update(Data())
            // Synthesize: only ctdbCRC32 matters for matching.
            return TrackChecksums(crc32: 0, accurateRipV1: 0, accurateRipV2: 0, ctdbCRC32: ctdb)
        }

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
        Harness.expect(result.trackVerdicts[1] == .accuratelyRipped(confidence: 2025), "track 1 verified by main entry")
        Harness.expect(result.trackVerdicts[2] == .accuratelyRipped(confidence: 28), "track 2 verified by alternate pressing")
        Harness.expect(result.trackVerdicts[3] == .differs(bestConfidence: 2025), "track 3 differs")
        Harness.expect(result.trackVerdicts[4] == .accuratelyRipped(confidence: 2025), "track 4 verified")
        Harness.expect(result.discMatch?.id == "14172", "whole-disc CRC matched")

        let empty = CTDBVerifier.match(
            entries: [],
            audioTrackNumbers: [1, 2],
            trackChecksums: [:],
            ctdbDiscCRC32: nil
        )
        Harness.expect(
            empty.trackVerdicts == [1: .notInDatabase, 2: .notInDatabase],
            "absent disc reported as neutral not-in-database"
        )
        Harness.expect(empty.summary == "Not in CTDB", "summary for unknown disc")
    }

    Harness.suite("CTDB checksum semantics") {
        // Toy stream large enough that the covered window is non-empty.
        let totalSamples = 30 * 588
        var bytes = Data(count: totalSamples * 4)
        for i in 0 ..< bytes.count { bytes[i] = UInt8((i &* 7) & 0xFF) }

        let prefix = 2940
        let suffix = 2940 + totalSamples % 2940 // == 2940 here

        var gated = RangeGatedCRC32(coveredBytes: prefix * 4 ..< (totalSamples - suffix) * 4)
        gated.update(bytes)
        let reference = CRC32.checksum(bytes.subdata(in: prefix * 4 ..< (totalSamples - suffix) * 4))
        Harness.expect(gated.value == reference, "range-gated CRC equals CRC of the covered slice")

        // Mutating skipped regions must not change the CRC.
        var mutated = bytes
        mutated[0] = 0xFF
        mutated[mutated.count - 1] = 0xFF
        var gated2 = RangeGatedCRC32(coveredBytes: prefix * 4 ..< (totalSamples - suffix) * 4)
        gated2.update(mutated)
        Harness.expect(gated2.value == reference, "bytes outside the window don't affect the CRC")

        // Mutating covered region must change it.
        var mutated2 = bytes
        mutated2[prefix * 4 + 100] ^= 0x01
        var gated3 = RangeGatedCRC32(coveredBytes: prefix * 4 ..< (totalSamples - suffix) * 4)
        gated3.update(mutated2)
        Harness.expect(gated3.value != reference, "bytes inside the window do affect the CRC")

        // Feeding in odd-sized chunks is equivalent.
        var gated4 = RangeGatedCRC32(coveredBytes: prefix * 4 ..< (totalSamples - suffix) * 4)
        var rest = bytes
        while !rest.isEmpty {
            let n = min(997, rest.count)
            gated4.update(rest.prefix(n))
            rest = rest.dropFirst(n)
        }
        Harness.expect(gated4.value == reference, "chunked feeding matches one-shot")
    }
}
