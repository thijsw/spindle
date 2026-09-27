import Foundation

/// Append-mostly history of finished jobs, persisted as JSON. Only the most
/// recent `limit` records are kept on disk — nothing reads further back.
public actor JobStore {
    public static let defaultLimit = 200

    private let fileURL: URL
    private let limit: Int
    private var records: [JobRecord]

    public init(directory: URL = PreferencesStore.applicationSupportURL, limit: Int = JobStore.defaultLimit) {
        self.fileURL = directory.appendingPathComponent("history.json")
        self.limit = limit
        self.records = JSONFile.load([JobRecord].self, from: fileURL, dates: .iso8601) ?? []
    }

    public func append(_ record: JobRecord) {
        records.append(record)
        if records.count > limit {
            records.removeFirst(records.count - limit)
        }
        do {
            try JSONFile.save(records, to: fileURL, dates: .iso8601)
        } catch {
            persistenceLog.error("Could not save job history: \(String(describing: error), privacy: .public)")
        }
    }

    /// Most recent first.
    public func history() -> [JobRecord] {
        records.reversed()
    }
}
