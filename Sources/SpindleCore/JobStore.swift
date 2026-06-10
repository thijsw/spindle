import Foundation

/// Append-mostly history of finished jobs, persisted as JSON.
public actor JobStore {
    private let fileURL: URL
    private var records: [JobRecord]

    public init(directory: URL = PreferencesStore.applicationSupportURL) {
        self.fileURL = directory.appendingPathComponent("history.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? decoder.decode([JobRecord].self, from: data) {
            self.records = loaded
        } else {
            self.records = []
        }
    }

    public func append(_ record: JobRecord) {
        records.append(record)
        persist()
    }

    public func history(limit: Int = 200) -> [JobRecord] {
        Array(records.suffix(limit).reversed())
    }

    public func clear() {
        records.removeAll()
        persist()
    }

    private func persist() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? (try? encoder.encode(records))?.write(to: fileURL)
    }
}
