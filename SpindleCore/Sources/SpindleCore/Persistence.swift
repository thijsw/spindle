import Foundation
import os

let persistenceLog = Logger(subsystem: "nl.huell.spindle", category: "persistence")

/// A JSON file holding one Codable value, pretty-printed with sorted keys
/// so a user can read and diff it. Loading tolerates an absent file (first
/// launch) silently and logs a malformed one; saving reports its failures.
enum JSONFile {
    static func load<T: Decodable>(
        _ type: T.Type, from url: URL, dates: JSONDecoder.DateDecodingStrategy = .deferredToDate
    ) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dates
        do {
            return try decoder.decode(type, from: data)
        } catch {
            persistenceLog.error("Ignoring malformed \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func save<T: Encodable>(
        _ value: T, to url: URL, dates: JSONEncoder.DateEncodingStrategy = .deferredToDate
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = dates
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
