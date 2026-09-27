import DiscDrive
import Foundation
import Net
import RipEngine

/// One submission entry in the CUETools Database.
public struct CTDBEntry: Sendable, Hashable {
    public let id: String
    public let confidence: Int
    public let discCRC32: UInt32
    public let trackCRC32s: [UInt32]
    public let hasParity: Bool

    public init(
        id: String, confidence: Int, discCRC32: UInt32, trackCRC32s: [UInt32],
        hasParity: Bool
    ) {
        self.id = id
        self.confidence = confidence
        self.discCRC32 = discCRC32
        self.trackCRC32s = trackCRC32s
        self.hasParity = hasParity
    }
}

public enum CTDBError: Error, CustomStringConvertible, Sendable, Equatable {
    case http(Int)
    case malformedResponse(String)
    case invalidBaseURL(URL)

    public var description: String {
        switch self {
        case .http(let code): "CTDB returned HTTP \(code)"
        case .malformedResponse(let detail): "Unexpected CTDB response: \(detail)"
        case .invalidBaseURL(let url): "CTDB base URL cannot take a query: \(url)"
        }
    }
}

/// CUETools Database client (db.cue.tools, public API).
public struct CTDBClient: Sendable {
    private let http: HTTPFetcher
    private let baseURL: URL

    public init(
        userAgent: String,
        baseURL: URL = URL(string: "https://db.cue.tools/lookup2.php")!,
        session: URLSession? = nil
    ) {
        self.http = HTTPFetcher(userAgent: userAgent, session: session)
        self.baseURL = baseURL
    }

    /// The CTDB TOC parameter: colon-separated track start LBAs (data tracks
    /// prefixed with "-") followed by the disc lead-out LBA.
    public static func tocParameter(for toc: TOC) -> String {
        var parts = toc.tracks.map { track in
            (track.isAudio ? "" : "-") + String(track.startLBA)
        }
        parts.append(String(toc.leadOutLBA))
        return parts.joined(separator: ":")
    }

    public func lookup(toc: TOC) async throws -> [CTDBEntry] {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CTDBError.invalidBaseURL(baseURL)
        }
        components.queryItems = [
            URLQueryItem(name: "version", value: "3"),
            URLQueryItem(name: "ctdb", value: "1"),
            URLQueryItem(name: "fuzzy", value: "1"),
            URLQueryItem(name: "toc", value: Self.tocParameter(for: toc)),
        ]
        guard let url = components.url else { throw CTDBError.invalidBaseURL(baseURL) }

        let response = try await http.get(url)
        guard response.status == 200 else { throw CTDBError.http(response.status) }
        return try Self.parse(xml: response.body)
    }

    public static func parse(xml: Data) throws -> [CTDBEntry] {
        let document: XMLDocument
        do {
            document = try XMLDocument(data: xml)
        } catch {
            throw CTDBError.malformedResponse(String(describing: error))
        }
        guard let root = document.rootElement(), root.localName == "ctdb" else {
            throw CTDBError.malformedResponse("missing <ctdb> root")
        }

        return root.children?.compactMap { node -> CTDBEntry? in
            guard let element = node as? XMLElement, element.localName == "entry" else { return nil }
            func attr(_ name: String) -> String? {
                element.attribute(forName: name)?.stringValue
            }
            guard let id = attr("id"),
                  let confidence = attr("confidence").flatMap(Int.init),
                  let crcHex = attr("crc32"),
                  let discCRC = UInt32(crcHex, radix: 16)
            else { return nil }
            let trackCRCs = (attr("trackcrcs") ?? "")
                .split(separator: " ")
                .compactMap { UInt32($0, radix: 16) }
            return CTDBEntry(
                id: id,
                confidence: confidence,
                discCRC32: discCRC,
                trackCRC32s: trackCRCs,
                hasParity: attr("hasparity") != nil
            )
        } ?? []
    }
}
