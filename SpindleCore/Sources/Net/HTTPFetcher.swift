import Foundation

/// Thin URLSession wrapper shared by the MusicBrainz, Cover Art Archive and
/// CTDB clients: one place for the session configuration, the mandatory
/// User-Agent header and the "was that even HTTP" check. Status handling
/// stays with each client — the services disagree on what 404 means.
public struct HTTPFetcher: Sendable {
    public struct Response: Sendable {
        public let status: Int
        public let body: Data
        /// The Content-Type header's media type, lower-cased and without
        /// parameters ("image/jpeg", never "image/jpeg; charset=…").
        public let mediaType: String?
    }

    public enum FetchError: Error, CustomStringConvertible, Sendable {
        case notHTTP(URL)

        public var description: String {
            switch self {
            case .notHTTP(let url): "\(url.host ?? url.absoluteString) did not answer with an HTTP response"
            }
        }
    }

    private let session: URLSession
    private let userAgent: String

    /// - Parameters:
    ///   - session: injected by tests; production gets an ephemeral session
    ///     with the given request timeout.
    ///   - accept: value for a fixed Accept header, when the service wants one.
    public init(userAgent: String, session: URLSession? = nil, timeout: TimeInterval = 30, accept: String? = nil) {
        self.userAgent = userAgent
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            if let accept {
                config.httpAdditionalHeaders = ["Accept": accept]
            }
            self.session = URLSession(configuration: config)
        }
    }

    public func get(_ url: URL) async throws -> Response {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.notHTTP(url) }
        let mediaType = http.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return Response(status: http.statusCode, body: data, mediaType: mediaType)
    }
}
