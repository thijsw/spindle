import DiscDrive
import Foundation
import RipEngine

/// One submission entry in the CUETools Database.
public struct CTDBEntry: Sendable, Hashable {
    public let id: String
    public let confidence: Int
    public let discCRC32: UInt32
    public let trackCRC32s: [UInt32]
    public let stride: Int
    public let hasParity: Bool
    public let tocString: String

    public init(
        id: String, confidence: Int, discCRC32: UInt32, trackCRC32s: [UInt32],
        stride: Int, hasParity: Bool, tocString: String
    ) {
        self.id = id
        self.confidence = confidence
        self.discCRC32 = discCRC32
        self.trackCRC32s = trackCRC32s
        self.stride = stride
        self.hasParity = hasParity
        self.tocString = tocString
    }
}

public enum CTDBError: Error, CustomStringConvertible, Sendable {
    case http(Int)
    case malformedResponse(String)

    public var description: String {
        switch self {
        case .http(let code): "CTDB returned HTTP \(code)"
        case .malformedResponse(let detail): "Unexpected CTDB response: \(detail)"
        }
    }
}

/// CUETools Database client (db.cue.tools, public API).
public struct CTDBClient: Sendable {
    private let session: URLSession
    private let userAgent: String
    private let baseURL: URL

    public init(
        userAgent: String,
        baseURL: URL = URL(string: "https://db.cue.tools/lookup2.php")!,
        session: URLSession? = nil
    ) {
        self.userAgent = userAgent
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: config)
        }
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
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "version", value: "3"),
            URLQueryItem(name: "ctdb", value: "1"),
            URLQueryItem(name: "fuzzy", value: "1"),
            URLQueryItem(name: "toc", value: Self.tocParameter(for: toc)),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CTDBError.malformedResponse("not an HTTP response")
        }
        guard http.statusCode == 200 else { throw CTDBError.http(http.statusCode) }
        return try Self.parse(xml: data)
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
                stride: attr("stride").flatMap(Int.init) ?? 5880,
                hasParity: attr("hasparity") != nil,
                tocString: attr("toc") ?? ""
            )
        } ?? []
    }
}
