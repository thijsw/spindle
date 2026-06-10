import DiscDrive
import Foundation

/// Builds a synthetic DKIOCCDREADTOC format-2 (full TOC, MSF) response.
private func makeFullTOC(descriptors: [[UInt8]], firstSession: UInt8 = 1, lastSession: UInt8 = 1) -> Data {
    let dataLength = UInt16(2 + descriptors.count * 11)
    var bytes: [UInt8] = [UInt8(dataLength >> 8), UInt8(dataLength & 0xFF), firstSession, lastSession]
    for d in descriptors {
        precondition(d.count == 11)
        bytes += d
    }
    return Data(bytes)
}

/// 11-byte descriptor: session, adr/control, tno, point, min, sec, frame, zero, pmin, psec, pframe.
private func descriptor(
    session: UInt8, adr: UInt8 = 1, control: UInt8, point: UInt8, lba: Int
) -> [UInt8] {
    let frames = lba + 150
    return [
        session, adr << 4 | control, 0, point,
        0, 0, 0, 0,
        UInt8(frames / (60 * 75)), UInt8((frames / 75) % 60), UInt8(frames % 75),
    ]
}

@MainActor
func tocParserTests() {
    Harness.suite("TOC parser") {
        let simple = makeFullTOC(descriptors: [
            descriptor(session: 1, control: 0x0, point: 0xA0, lba: 1 * 75 - 150),
            descriptor(session: 1, control: 0x0, point: 0xA1, lba: 3 * 75 - 150),
            descriptor(session: 1, control: 0x0, point: 0xA2, lba: 15000),
            descriptor(session: 1, control: 0x0, point: 1, lba: 0),
            descriptor(session: 1, control: 0x0, point: 2, lba: 5000),
            descriptor(session: 1, control: 0x1, point: 3, lba: 10000),
        ])
        if let toc = try? TOC.parse(fullTOC: simple) {
            Harness.expect(toc.tracks.map(\.number) == [1, 2, 3], "parses three tracks in order")
            Harness.expect(toc.tracks.map(\.startLBA) == [0, 5000, 10000], "track start LBAs")
            Harness.expect(toc.leadOutLBA == 15000, "lead-out LBA")
            Harness.expect(toc.tracks.allSatisfy(\.isAudio), "all audio")
            Harness.expect(toc.tracks[2].hasPreEmphasis, "pre-emphasis flag from control bits")
            Harness.expect(toc.lengthInSectors(of: toc.tracks[0]) == 5000, "length to next track")
            Harness.expect(toc.lengthInSectors(of: toc.tracks[2]) == 5000, "last track length to lead-out")
            Harness.expect(toc.totalAudioSectors == 15000, "total audio sectors")
        } else {
            Harness.expect(false, "simple audio disc parses")
        }

        let withData = makeFullTOC(descriptors: [
            descriptor(session: 1, control: 0x0, point: 1, lba: 0),
            descriptor(session: 1, control: 0x4, point: 2, lba: 20000),
            descriptor(session: 1, control: 0x0, point: 0xA2, lba: 40000),
        ])
        if let toc = try? TOC.parse(fullTOC: withData) {
            Harness.expect(!toc.tracks[1].isAudio && toc.audioTracks.count == 1, "data track marked from control bits")
        } else {
            Harness.expect(false, "disc with data track parses")
        }

        let multiSession = makeFullTOC(descriptors: [
            descriptor(session: 1, control: 0x0, point: 1, lba: 0),
            descriptor(session: 1, control: 0x0, point: 0xA2, lba: 30000),
            descriptor(session: 2, control: 0x4, point: 2, lba: 41400),
            descriptor(session: 2, control: 0x0, point: 0xA2, lba: 60000),
        ], firstSession: 1, lastSession: 2)
        if let toc = try? TOC.parse(fullTOC: multiSession) {
            Harness.expect(toc.sessionLeadOuts == [1: 30000, 2: 60000], "per-session lead-outs")
            Harness.expect(toc.leadOutLBA == 60000, "disc lead-out is last session's")
            Harness.expect(toc.lengthInSectors(of: toc.tracks[0]) == 30000, "session 1 track ends at session 1 lead-out")
        } else {
            Harness.expect(false, "multi-session disc parses")
        }

        let withADR5 = makeFullTOC(descriptors: [
            descriptor(session: 1, adr: 5, control: 0x0, point: 1, lba: 7777),
            descriptor(session: 1, control: 0x0, point: 1, lba: 0),
            descriptor(session: 1, control: 0x0, point: 0xA2, lba: 10000),
        ])
        if let toc = try? TOC.parse(fullTOC: withADR5) {
            Harness.expect(toc.tracks.count == 1 && toc.tracks[0].startLBA == 0, "ADR≠1 descriptors skipped")
        } else {
            Harness.expect(false, "disc with ADR 5 entries parses")
        }

        Harness.expectThrows("truncated data rejected") {
            try TOC.parse(fullTOC: Data([0x00]))
        }
        Harness.expectThrows("descriptor-free TOC rejected") {
            try TOC.parse(fullTOC: makeFullTOC(descriptors: []))
        }
    }
}
