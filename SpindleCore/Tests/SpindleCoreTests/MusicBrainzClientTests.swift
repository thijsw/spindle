import Foundation
import Metadata
import Testing

/// Captures every request the client makes and answers from a script.
/// URLProtocol subclasses are looked up by class, so the state is static.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var requests: [(URLRequest, ContinuousClock.Instant)] = []
    nonisolated(unsafe) private static var responder: @Sendable (URLRequest) -> (Int, Data) = { _ in (404, Data()) }
    private static let lock = NSLock()

    static func reset(responder: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        lock.withLock {
            requests = []
            Self.responder = responder
        }
    }

    static var recorded: [(URLRequest, ContinuousClock.Instant)] { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.lock.withLock {
            Self.requests.append((request, .now))
            return Self.responder(request)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: config)
}

private let disc = DiscTOC(firstTrack: 1, lastTrack: 2, leadOutOffset: 20000, trackOffsets: [150, 10000])

@Suite(.serialized) struct MusicBrainzClientTests {
    @Test func discIDHitIsReportedAsMatchedWithTheMandatoryUserAgent() async throws {
        StubProtocol.reset { request in
            let body = """
            { "id": "x", "releases": [ { "id": "REL-1", "title": "Found", "media": [] } ] }
            """
            return (200, Data(body.utf8))
        }
        let client = MusicBrainzClient(
            userAgent: "Spindle/test ( test@example.com )", session: stubbedSession(), minimumInterval: .zero
        )
        guard case .matched(let releases) = try await client.lookup(disc: disc) else {
            Issue.record("expected a DiscID match")
            return
        }
        #expect(releases.map(\.title) == ["Found"])
        let requests = StubProtocol.recorded
        #expect(requests.count == 1)
        #expect(requests[0].0.value(forHTTPHeaderField: "User-Agent") == "Spindle/test ( test@example.com )")
        #expect(requests[0].0.url?.path == "/ws/2/discid/\(disc.musicBrainzDiscID)")
        #expect(requests[0].0.url?.query?.contains("inc=recordings") == true)
    }

    @Test func unknownDiscIDFallsBackToFuzzyTOCLookup() async throws {
        StubProtocol.reset { request in
            if request.url?.path.hasSuffix("/discid/-") == true {
                return (200, Data(#"{ "releases": [ { "id": "REL-9", "title": "Fuzzy", "media": [] } ] }"#.utf8))
            }
            return (404, Data())
        }
        let client = MusicBrainzClient(userAgent: "t", session: stubbedSession(), minimumInterval: .zero)
        guard case .fuzzy(let releases) = try await client.lookup(disc: disc) else {
            Issue.record("expected a fuzzy match after the 404")
            return
        }
        #expect(releases.first?.title == "Fuzzy")
        #expect(StubProtocol.recorded[1].0.url?.query?.contains("toc=1+2+20000+150+10000") == true)
    }

    /// Regression: concurrent callers used to observe the same "last request"
    /// time, sleep the same remainder and then fire together.
    @Test func concurrentCallersAreSpacedByTheThrottle() async throws {
        StubProtocol.reset { _ in (404, Data()) }
        let interval: Duration = .milliseconds(120)
        let client = MusicBrainzClient(userAgent: "t", session: stubbedSession(), minimumInterval: interval)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 3 {
                group.addTask { _ = try? await client.lookup(disc: disc) }
            }
        }

        // Three lookups × (discid + fuzzy) = six requests, each at least one
        // interval after the previous.
        // Timestamps are taken when URLSession starts loading, so individual
        // gaps jitter; the unthrottled behaviour would show near-zero gaps.
        let times = StubProtocol.recorded.map(\.1).sorted()
        #expect(times.count == 6)
        for (earlier, later) in zip(times, times.dropFirst()) {
            #expect(later - earlier >= interval * 0.75, "requests only \(later - earlier) apart")
        }
        if let first = times.first, let last = times.last {
            #expect(last - first >= interval * 5 - .milliseconds(20), "six requests span five intervals")
        }
    }

    @Test func serverErrorsSurfaceAsHTTPErrors() async {
        StubProtocol.reset { _ in (500, Data()) }
        let client = MusicBrainzClient(userAgent: "t", session: stubbedSession(), minimumInterval: .zero)
        await #expect(throws: MusicBrainzError.self) {
            try await client.lookup(disc: disc)
        }
    }
}
