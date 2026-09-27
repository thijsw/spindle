import Foundation
import Transfer

/// Display formatting shared by the app, the CLI and the rip log.
public enum DisplayFormat {
    /// "3:07" for 187 seconds.
    public static func minutesSeconds(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// "1.2 MB/s" / "480 KB/s".
    public static func transferRate(_ bytesPerSecond: Double) -> String {
        let mb = bytesPerSecond / 1_000_000
        if mb >= 1 { return String(format: "%.1f MB/s", mb) }
        return String(format: "%.0f KB/s", bytesPerSecond / 1000)
    }
}

/// Pure functions from job snapshots to the one-line texts the app shows.
/// They live here (not in the app) so they can be unit-tested.
public enum JobPresentation {
    /// The job the main window focuses on: the most recent non-terminal one.
    public static func activeJob(in jobs: [JobSnapshot]) -> JobSnapshot? {
        jobs.last { !$0.stage.isTerminal }
    }

    /// Coarse text for the menu bar; changes only on stage transitions.
    public static func menuBarSummary(jobs: [JobSnapshot]) -> String {
        guard let job = activeJob(in: jobs) else { return "Waiting for a disc" }
        return "\(job.displayTitle) — \(job.stage.label)"
    }

    /// One line describing what the app is doing right now. Prefers the
    /// most downstream activity (uploading), so the user sees the step that
    /// is actually taking time.
    public static func statusText(
        jobs: [JobSnapshot],
        transferFraction: [JobID: Double],
        transferRate: [JobID: Double],
        hasDestination: Bool
    ) -> String {
        let active = jobs.filter { !$0.stage.isTerminal }
        guard !active.isEmpty else {
            return hasDestination ? "Ready — insert a disc" : "No destination set — open Settings"
        }
        func title(_ job: JobSnapshot) -> String { job.album?.album ?? "Audio CD" }

        if let job = active.first(where: { $0.stage == .transferring }) {
            let pct = Int((transferFraction[job.id] ?? 0) * 100)
            let bps = transferRate[job.id] ?? 0
            let speed = bps > 0 ? " · \(DisplayFormat.transferRate(bps))" : ""
            return "Uploading \(title(job)) — \(pct)%\(speed)"
        }
        if let job = active.first(where: { $0.stage == .encoding }) {
            return "Encoding \(title(job))"
        }
        // `active` is non-empty, so there is always a most recent active job.
        let job = activeJob(in: jobs) ?? active[0]
        if job.stage == .ripping, let detail = rippingTrackDetail(job) {
            return "Ripping \(title(job)) — \(detail)"
        }
        return "\(job.stage.label) — \(title(job))"
    }

    /// "track N of M" for the track currently being read, or nil.
    public static func rippingTrackDetail(_ job: JobSnapshot) -> String? {
        guard let current = job.tracks.first(where: {
            if case .ripping = $0.status { return true } else { return false }
        }) else { return nil }
        return "track \(current.number) of \(job.tracks.count)"
    }
}

/// Editable form state for the Destination settings pane, kept apart from
/// the persisted `DestinationConfig` so half-typed fields never reach the
/// pipeline and the conversion can be tested without SwiftUI.
public struct DestinationDraft: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case none = "None"
        case folder = "Local Folder"
        case sftp = "SFTP Server"
    }

    public var kind: Kind = .none
    public var folderPath = ""
    public var host = ""
    public var port = 22
    public var username = ""
    public var remotePath = ""
    public var usesKeyFile = false
    public var keyFile = ""

    public init(_ config: DestinationConfig?) {
        switch config {
        case nil:
            kind = .none
        case .localFolder(let path):
            kind = .folder
            folderPath = path
        case .sftp(let sftp):
            kind = .sftp
            host = sftp.host
            port = sftp.port
            username = sftp.username
            remotePath = sftp.remotePath
            if case .privateKeyFile(let path) = sftp.authentication {
                usesKeyFile = true
                keyFile = path
            }
        }
    }

    /// The configuration the draft describes, or nil while required fields
    /// are still empty (or the kind is none).
    public var config: DestinationConfig? {
        switch kind {
        case .none:
            return nil
        case .folder:
            return folderPath.isEmpty ? nil : .localFolder(path: folderPath)
        case .sftp:
            guard !host.isEmpty, !username.isEmpty else { return nil }
            return .sftp(SFTPConfig(
                host: host,
                port: port,
                username: username,
                authentication: usesKeyFile ? .privateKeyFile(path: keyFile) : .password,
                remotePath: remotePath.isEmpty ? "." : remotePath
            ))
        }
    }

    /// Keychain account of the SFTP secret, when the draft is a complete SFTP config.
    public var keychainAccount: String? {
        if case .sftp(let sftp)? = config { return sftp.keychainAccount }
        return nil
    }
}
