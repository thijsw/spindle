import Foundation

public enum MusicBrainzError: Error, CustomStringConvertible, Sendable {
    case http(Int)
    case rateLimitedRepeatedly
    case invalidResponse(String)

    public var description: String {
        switch self {
        case .http(let code): "MusicBrainz returned HTTP \(code)"
        case .rateLimitedRepeatedly: "MusicBrainz keeps rate-limiting us; try again later"
        case .invalidResponse(let detail): "Unexpected MusicBrainz response: \(detail)"
        }
    }
}

public enum DiscLookupResult: Sendable {
    /// The DiscID is known; releases are attached to it.
    case matched([MBRelease])
    /// Unknown DiscID, but a fuzzy TOC search found candidates.
    case fuzzy([MBRelease])
    /// Nothing found.
    case none
}

/// MusicBrainz WS/2 client. An actor so the mandatory 1-request/second
/// throttle is enforced across all callers.
public actor MusicBrainzClient {
    public static let includes = "recordings+artist-credits+release-groups+labels"

    private let session: URLSession
    private let userAgent: String
    private let baseURL: URL
    /// The instant the most recently *reserved* request slot may fire.
    /// Reserved before sleeping, so concurrent callers queue up one interval
    /// apart instead of all waking at the same moment.
    private var nextSlot: ContinuousClock.Instant?
    private let minimumInterval: Duration

    /// `minimumInterval` exists for tests; production keeps MusicBrainz's
    /// mandatory one request per second (with margin).
    public init(
        userAgent: String,
        baseURL: URL = URL(string: "https://musicbrainz.org/ws/2")!,
        session: URLSession? = nil,
        minimumInterval: Duration = .seconds(1.1)
    ) {
        self.userAgent = userAgent
        self.baseURL = baseURL
        self.minimumInterval = minimumInterval
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.httpAdditionalHeaders = ["Accept": "application/json"]
            self.session = URLSession(configuration: config)
        }
    }

    /// Looks up releases for a disc: direct DiscID lookup first, then a fuzzy
    /// TOC lookup if the DiscID is unknown to MusicBrainz.
    public func lookup(disc: DiscTOC) async throws -> DiscLookupResult {
        let discID = disc.musicBrainzDiscID
        let toc = disc.musicBrainzTOCString.replacingOccurrences(of: " ", with: "+")

        let direct = try await get(
            path: "discid/\(discID)",
            query: "inc=\(Self.includes)&cdstubs=no&fmt=json"
        )
        if let direct {
            let decoded = try decode(MBDiscIDResponse.self, from: direct)
            if let releases = decoded.releases, !releases.isEmpty {
                return .matched(releases)
            }
        }

        // 404 or no attached releases: fuzzy TOC match.
        let fuzzy = try await get(
            path: "discid/-",
            query: "toc=\(toc)&inc=\(Self.includes)&cdstubs=no&fmt=json"
        )
        if let fuzzy {
            let decoded = try decode(MBDiscIDResponse.self, from: fuzzy)
            if let releases = decoded.releases, !releases.isEmpty {
                return .fuzzy(releases)
            }
        }
        return .none
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MusicBrainzError.invalidResponse(String(describing: error))
        }
    }

    /// Throttled GET. Returns nil on 404 (a normal "not found" outcome).
    private func get(path: String, query: String) async throws -> Data? {
        var attempt = 0
        while true {
            try await throttle()

            var request = URLRequest(url: url(path: path, query: query))
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MusicBrainzError.invalidResponse("not an HTTP response")
            }

            switch http.statusCode {
            case 200:
                return data
            case 404:
                return nil
            case 503, 429:
                attempt += 1
                guard attempt <= 3 else { throw MusicBrainzError.rateLimitedRepeatedly }
                try await Task.sleep(for: .seconds(Double(attempt) * 2))
            default:
                throw MusicBrainzError.http(http.statusCode)
            }
        }
    }

    private func url(path: String, query: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.path = (components.path as NSString).appendingPathComponent(path)
        components.percentEncodedQuery = query
        // The base URL and the query are built from known-good literals;
        // only a corrupt injected base could fail here.
        return components.url ?? baseURL
    }

    /// Reserves the next request slot and waits for it. Because the slot is
    /// claimed *before* suspending, N concurrent callers fire N intervals
    /// apart — the actor's reentrancy can't collapse them onto one instant.
    private func throttle() async throws {
        let now = ContinuousClock.now
        let slot = nextSlot.map { max($0, now) } ?? now
        nextSlot = slot + minimumInterval
        if slot > now {
            try await Task.sleep(until: slot, clock: .continuous)
        }
    }
}
