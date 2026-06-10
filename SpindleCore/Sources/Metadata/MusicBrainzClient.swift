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
    private var lastRequestAt: ContinuousClock.Instant?
    private let minimumInterval: Duration = .seconds(1.1)

    public init(
        userAgent: String,
        baseURL: URL = URL(string: "https://musicbrainz.org/ws/2")!,
        session: URLSession? = nil
    ) {
        self.userAgent = userAgent
        self.baseURL = baseURL
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

            var request = URLRequest(url: URL(string: "\(baseURL.absoluteString)/\(path)?\(query)")!)
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

    private func throttle() async throws {
        if let last = lastRequestAt {
            let elapsed = ContinuousClock.now - last
            if elapsed < minimumInterval {
                try await Task.sleep(for: minimumInterval - elapsed)
            }
        }
        lastRequestAt = ContinuousClock.now
    }
}
