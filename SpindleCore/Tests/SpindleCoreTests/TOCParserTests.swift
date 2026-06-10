import DiscDrive
import Foundation
import Testing

@Suite struct TOCParserTests {
    @Test func parsesSimpleAudioDisc() throws {
        let raw = makeFullTOC(descriptors: [
            tocDescriptor(session: 1, control: 0x0, point: 0xA0, lba: 1 * 75 - 150),
            tocDescriptor(session: 1, control: 0x0, point: 0xA1, lba: 3 * 75 - 150),
            tocDescriptor(session: 1, control: 0x0, point: 0xA2, lba: 15000), // lead-out
            tocDescriptor(session: 1, control: 0x0, point: 1, lba: 0),
            tocDescriptor(session: 1, control: 0x0, point: 2, lba: 5000),
            tocDescriptor(session: 1, control: 0x1, point: 3, lba: 10000), // pre-emphasis
        ])

        let toc = try TOC.parse(fullTOC: raw)
        #expect(toc.tracks.map(\.number) == [1, 2, 3])
        #expect(toc.tracks.map(\.startLBA) == [0, 5000, 10000])
        #expect(toc.leadOutLBA == 15000)
        let allAudio = toc.tracks.allSatisfy(\.isAudio)
        #expect(allAudio)
        #expect(toc.tracks[2].hasPreEmphasis)
        #expect(toc.lengthInSectors(of: toc.tracks[0]) == 5000)
        #expect(toc.lengthInSectors(of: toc.tracks[2]) == 5000)
        #expect(toc.totalAudioSectors == 15000)
    }

    @Test func marksDataTracksFromControlBits() throws {
        let raw = makeFullTOC(descriptors: [
            tocDescriptor(session: 1, control: 0x0, point: 1, lba: 0),
            tocDescriptor(session: 1, control: 0x4, point: 2, lba: 20000), // data track
            tocDescriptor(session: 1, control: 0x0, point: 0xA2, lba: 40000),
        ])

        let toc = try TOC.parse(fullTOC: raw)
        #expect(toc.tracks[0].isAudio)
        #expect(!toc.tracks[1].isAudio)
        #expect(toc.audioTracks.count == 1)
    }

    @Test func parsesMultiSessionDisc() throws {
        let raw = makeFullTOC(descriptors: [
            tocDescriptor(session: 1, control: 0x0, point: 1, lba: 0),
            tocDescriptor(session: 1, control: 0x0, point: 0xA2, lba: 30000),
            tocDescriptor(session: 2, control: 0x4, point: 2, lba: 41400),
            tocDescriptor(session: 2, control: 0x0, point: 0xA2, lba: 60000),
        ], firstSession: 1, lastSession: 2)

        let toc = try TOC.parse(fullTOC: raw)
        #expect(toc.firstSession == 1)
        #expect(toc.lastSession == 2)
        #expect(toc.sessionLeadOuts == [1: 30000, 2: 60000])
        #expect(toc.leadOutLBA == 60000)
        // Last track of session 1 extends to session 1's lead-out, not the disc's.
        #expect(toc.lengthInSectors(of: toc.tracks[0]) == 30000)
    }

    @Test func skipsNonPositionDescriptors() throws {
        let raw = makeFullTOC(descriptors: [
            tocDescriptor(session: 1, adr: 5, control: 0x0, point: 1, lba: 7777), // ADR 5: not a position
            tocDescriptor(session: 1, control: 0x0, point: 1, lba: 0),
            tocDescriptor(session: 1, control: 0x0, point: 0xA2, lba: 10000),
        ])

        let toc = try TOC.parse(fullTOC: raw)
        #expect(toc.tracks.count == 1)
        #expect(toc.tracks[0].startLBA == 0)
    }

    @Test func rejectsTruncatedData() {
        #expect(throws: TOCParseError.self) {
            try TOC.parse(fullTOC: Data([0x00]))
        }
        #expect(throws: TOCParseError.self) {
            try TOC.parse(fullTOC: makeFullTOC(descriptors: []))
        }
    }
}
