import Foundation
import Metadata
import Testing

private let disc = DiscTOC(firstTrack: 1, lastTrack: 2, leadOutOffset: 20000, trackOffsets: [150, 10000])

@Suite struct MusicBrainzClientTests {
    @Test func discIDHitIsReportedAsMatchedWithTheMandatoryUserAgent() async throws {
        let stub = HTTPStub { _ in
            let body = """
            { "id": "x", "releases": [ { "id": "REL-1", "title": "Found", "media": [] } ] }
            """
            return (200, Data(body.utf8))
        }
        let client = MusicBrainzClient(
            userAgent: "Spindle/test ( test@example.com )", session: stub.session(), minimumInterval: .zero
        )
        guard case .matched(let releases) = try await client.lookup(disc: disc) else {
            Issue.record("expected a DiscID match")
            return
        }
        #expect(releases.map(\.title) == ["Found"])
        let requests = stub.recorded
        #expect(requests.count == 1)
        #expect(requests[0].request.value(forHTTPHeaderField: "User-Agent") == "Spindle/test ( test@example.com )")
        #expect(requests[0].request.url?.path == "/ws/2/discid/\(disc.musicBrainzDiscID)")
        #expect(requests[0].request.url?.query?.contains("inc=recordings") == true)
    }

    @Test func unknownDiscIDFallsBackToFuzzyTOCLookup() async throws {
        let stub = HTTPStub { request in
            if request.url?.path.hasSuffix("/discid/-") == true {
                return (200, Data(#"{ "releases": [ { "id": "REL-9", "title": "Fuzzy", "media": [] } ] }"#.utf8))
            }
            return (404, Data())
        }
        let client = MusicBrainzClient(userAgent: "t", session: stub.session(), minimumInterval: .zero)
        guard case .fuzzy(let releases) = try await client.lookup(disc: disc) else {
            Issue.record("expected a fuzzy match after the 404")
            return
        }
        #expect(releases.first?.title == "Fuzzy")
        #expect(stub.recorded[1].request.url?.query?.contains("toc=1+2+20000+150+10000") == true)
    }

    /// Regression: concurrent callers used to observe the same "last request"
    /// time, sleep the same remainder and then fire together.
    @Test func concurrentCallersAreSpacedByTheThrottle() async throws {
        let stub = HTTPStub { _ in (404, Data()) }
        let interval: Duration = .milliseconds(120)
        let client = MusicBrainzClient(userAgent: "t", session: stub.session(), minimumInterval: interval)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 3 {
                group.addTask { _ = try? await client.lookup(disc: disc) }
            }
        }

        // Three lookups × (discid + fuzzy) = six requests, each at least one
        // interval after the previous.
        // Six requests (three lookups × discid + fuzzy) each hold a reserved
        // slot one interval apart, so the last can never fire before five
        // intervals have passed. Scheduling delays under test load only push
        // requests later, so the total span is the robust assertion — the
        // unthrottled behaviour spans a single interval.
        let times = stub.recorded.map(\.time).sorted()
        #expect(times.count == 6)
        if let first = times.first, let last = times.last {
            #expect(last - first >= interval * 5 - .milliseconds(20), "six requests span five intervals (got \(last - first))")
        }
    }

    @Test func serverErrorsSurfaceAsHTTPErrors() async {
        let stub = HTTPStub { _ in (500, Data()) }
        let client = MusicBrainzClient(userAgent: "t", session: stub.session(), minimumInterval: .zero)
        await #expect(throws: MusicBrainzError.self) {
            try await client.lookup(disc: disc)
        }
    }
}
