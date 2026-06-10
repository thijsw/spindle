import Foundation

public struct CoverArt: Sendable {
    public enum Source: String, Sendable {
        case coverArtArchive
        case coverArtArchiveReleaseGroup
        case iTunes
    }

    public let data: Data
    public let mimeType: String
    public let source: Source

    public init(data: Data, mimeType: String, source: Source) {
        self.data = data
        self.mimeType = mimeType
        self.source = source
    }

    public var fileExtension: String {
        switch mimeType {
        case "image/png": "png"
        default: "jpg"
        }
    }
}

public enum CoverArtSize: String, Sendable, Codable, CaseIterable {
    case small = "front-250"
    case medium = "front-500"
    case large = "front-1200"
    case original = "front"
}

/// Fetches album art: Cover Art Archive for the release, then the release
/// group, then the iTunes Search API as a last resort.
public struct CoverArtClient: Sendable {
    private let session: URLSession
    private let userAgent: String

    public init(userAgent: String, session: URLSession? = nil) {
        self.userAgent = userAgent
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            self.session = URLSession(configuration: config)
        }
    }

    public func fetchArt(
        releaseMBID: String?,
        releaseGroupMBID: String?,
        fallbackQuery: String?,
        size: CoverArtSize = .large
    ) async -> CoverArt? {
        if let releaseMBID,
           let art = await fetchCAA(path: "release/\(releaseMBID)/\(size.rawValue)", source: .coverArtArchive) {
            return art
        }
        if let releaseGroupMBID,
           let art = await fetchCAA(path: "release-group/\(releaseGroupMBID)/\(size.rawValue)", source: .coverArtArchiveReleaseGroup) {
            return art
        }
        if let fallbackQuery {
            return await fetchITunes(query: fallbackQuery)
        }
        return nil
    }

    private func fetchCAA(path: String, source: CoverArt.Source) async -> CoverArt? {
        await fetchImage(url: URL(string: "https://coverartarchive.org/\(path)")!, source: source)
    }

    private func fetchITunes(query: String) async -> CoverArt? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components.url,
              let (data, response) = try? await session.data(for: request(url)),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }

        struct SearchResponse: Decodable {
            struct Result: Decodable { let artworkUrl100: String? }
            let results: [Result]
        }
        guard let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data),
              let artwork = decoded.results.first?.artworkUrl100,
              // The CDN serves larger renditions by changing the size segment.
              let largeURL = URL(string: artwork.replacingOccurrences(of: "100x100bb", with: "1200x1200bb"))
        else { return nil }

        return await fetchImage(url: largeURL, source: .iTunes)
    }

    private func fetchImage(url: URL, source: CoverArt.Source) async -> CoverArt? {
        guard let (data, response) = try? await session.data(for: request(url)),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              data.count > 1000 // reject error pages
        else { return nil }
        let mime = http.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg"
        return CoverArt(data: data, mimeType: mime, source: source)
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }
}
