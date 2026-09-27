import DiscDrive
import Foundation
import Metadata
import Testing
import Verification

private let tinyImage = Data(repeating: 0x7F, count: 4096)

@Suite struct CoverArtClientTests {
    @Test func fallsBackFromReleaseToReleaseGroupToITunes() async {
        let stub = HTTPStub { request -> (status: Int, body: Data, headers: [String: String]) in
            let path = request.url?.path ?? ""
            if path.hasPrefix("/release/") { return (404, Data(), [:]) }
            if path.hasPrefix("/release-group/") { return (200, tinyImage, ["Content-Type": "image/png; charset=binary"]) }
            return (500, Data(), [:])
        }
        let client = CoverArtClient(userAgent: "t", session: stub.session())
        let art = await client.fetchArt(releaseMBID: "REL", releaseGroupMBID: "RG", fallbackQuery: "x y", size: .large)
        #expect(art?.source == .coverArtArchiveReleaseGroup)
        #expect(art?.mimeType == "image/png", "Content-Type parameters are stripped")
        #expect(art?.fileExtension == "png")
        #expect(stub.recorded.map { $0.request.url?.path ?? "" } == ["/release/REL/front-1200", "/release-group/RG/front-1200"])
        #expect(stub.recorded.allSatisfy { $0.request.value(forHTTPHeaderField: "User-Agent") == "t" })
    }

    @Test func tinyBodiesAreRejectedAsErrorPages() async {
        let stub = HTTPStub { request -> (status: Int, body: Data, headers: [String: String]) in
            if request.url?.host == "itunes.apple.com" {
                return (200, Data(#"{ "results": [ { "artworkUrl100": "https://is1.mzstatic.com/a/100x100bb.jpg" } ] }"#.utf8), [:])
            }
            if request.url?.host == "is1.mzstatic.com" { return (200, tinyImage, ["Content-Type": "image/jpeg"]) }
            return (200, Data("<html>not found</html>".utf8), [:]) // CAA "error page" with 200
        }
        let client = CoverArtClient(userAgent: "t", session: stub.session())
        let art = await client.fetchArt(releaseMBID: "REL", releaseGroupMBID: nil, fallbackQuery: "Artist Album", size: .medium)
        #expect(art?.source == .iTunes, "CAA's tiny body is rejected; iTunes wins")
        #expect(stub.recorded.contains { $0.request.url?.absoluteString.contains("1200x1200bb") == true }, "large rendition requested")
    }

    @Test func noQueryMeansNoITunesLookup() async {
        let stub = HTTPStub { _ in (404, Data()) }
        let client = CoverArtClient(userAgent: "t", session: stub.session())
        let art = await client.fetchArt(releaseMBID: nil, releaseGroupMBID: nil, fallbackQuery: nil, size: .large)
        #expect(art == nil)
        #expect(stub.recorded.isEmpty, "nothing to ask anyone")
    }
}

@Suite struct CTDBClientHTTPTests {
    private let toc = makeTOC(trackSectors: [0 ..< 9550, 9550 ..< 25737], leadOut: 39147)

    @Test func requestCarriesTOCVersionAndUserAgent() async throws {
        let stub = HTTPStub { _ in
            (200, Data("<ctdb><entry id=\"1\" confidence=\"3\" crc32=\"0000000a\" trackcrcs=\"1 2\" /></ctdb>".utf8))
        }
        let client = CTDBClient(userAgent: "Spindle/test", session: stub.session())
        let entries = try await client.lookup(toc: toc)
        #expect(entries.map(\.confidence) == [3])
        let request = try #require(stub.recorded.first?.request)
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["version"] == "3" && query["ctdb"] == "1" && query["fuzzy"] == "1")
        #expect(query["toc"] == "0:9550:39147")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Spindle/test")
    }

    @Test func httpAndParseFailuresAreDistinct() async {
        let failing = CTDBClient(userAgent: "t", session: HTTPStub { _ in (503, Data()) }.session())
        await #expect(throws: CTDBError.http(503)) { try await failing.lookup(toc: toc) }

        let garbled = CTDBClient(userAgent: "t", session: HTTPStub { _ in (200, Data("<nope/>".utf8)) }.session())
        do {
            _ = try await garbled.lookup(toc: toc)
            Issue.record("expected a parse failure")
        } catch CTDBError.malformedResponse {
            // expected
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func parserSkipsEntriesWithMissingAttributes() throws {
        let xml = """
        <ctdb>
          <entry id="ok" confidence="7" crc32="deadbeef" trackcrcs="1 2 3" />
          <entry id="no-crc" confidence="7" />
          <entry confidence="7" crc32="1" />
          <other />
        </ctdb>
        """
        let entries = try CTDBClient.parse(xml: Data(xml.utf8))
        #expect(entries.map(\.id) == ["ok"])
        #expect(entries[0].discCRC32 == 0xDEAD_BEEF && entries[0].trackCRC32s == [1, 2, 3])
        #expect(throws: CTDBError.self) { try CTDBClient.parse(xml: Data("not xml".utf8)) }
    }
}
