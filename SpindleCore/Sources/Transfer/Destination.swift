import Foundation

public extension URL {
    /// Size of a regular file in bytes, or nil when it can't be read.
    var fileSize: Int64? {
        (try? resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }
}

public struct TransferProgress: Sendable {
    public let bytesSent: Int64
    public let totalBytes: Int64
}

/// A place finished albums are delivered to.
public protocol Destination: Sendable {
    /// Verifies the destination is reachable and writable.
    func prepare() async throws

    /// Uploads one file. Implementations write to a temporary name and
    /// rename on completion so observers (e.g. Navidrome's scanner) never
    /// see partial files.
    func upload(
        file: URL,
        toRelativePath relativePath: String,
        progress: (@Sendable (TransferProgress) -> Void)?
    ) async throws

    /// Human-readable connectivity check for the Settings "Test" button.
    func test() async -> Result<String, Error>

    /// Releases connections. Safe to call repeatedly.
    func close() async
}

public enum DestinationError: Error, CustomStringConvertible, Sendable {
    case notWritable(String)
    case connectionFailed(String)
    case uploadFailed(path: String, reason: String)
    case missingCredentials(String)
    case hostKeyMismatch(host: String, expected: String, actual: String)

    public var description: String {
        switch self {
        case .notWritable(let path): "Destination is not writable: \(path)"
        case .connectionFailed(let reason): "Connection failed: \(reason)"
        case .uploadFailed(let path, let reason): "Upload of \(path) failed: \(reason)"
        case .missingCredentials(let account): "No saved credentials for \(account)"
        case .hostKeyMismatch(let host, _, let actual):
            "The SSH host key for \(host) has changed (now \(actual)). The transfer was refused — this can mean a man-in-the-middle. If you know the server's key legitimately changed, forget the saved host key in Settings, then reconnect."
        }
    }

    /// Whether retrying a moment later could plausibly succeed. Credential
    /// and host-key problems need the user, not a second attempt.
    public var isTransient: Bool {
        switch self {
        case .connectionFailed, .uploadFailed: true
        case .notWritable, .missingCredentials, .hostKeyMismatch: false
        }
    }
}

/// User-configurable destination description (persisted in preferences;
/// secrets live in the Keychain).
public enum DestinationConfig: Sendable, Codable, Equatable {
    case localFolder(path: String)
    case sftp(SFTPConfig)

    public var displayName: String {
        switch self {
        case .localFolder(let path):
            "Folder: \((path as NSString).abbreviatingWithTildeInPath)"
        case .sftp(let config):
            "SFTP: \(config.username)@\(config.host)\(config.remotePath)"
        }
    }
}

public extension DestinationConfig {
    /// Parses a command-line destination: `sftp://user@host[:port]/remote/path`
    /// (password authentication; adjust afterwards for a key file) or a local
    /// folder path. Nil for an SFTP URL without a user or host.
    static func parse(_ spec: String) -> DestinationConfig? {
        guard spec.hasPrefix("sftp://") else { return .localFolder(path: spec) }
        guard let url = URL(string: spec), let host = url.host, let user = url.user else { return nil }
        return .sftp(SFTPConfig(
            host: host,
            port: url.port ?? 22,
            username: user,
            remotePath: url.path.isEmpty ? "." : url.path
        ))
    }
}

public struct SFTPConfig: Sendable, Codable, Equatable {
    public var host: String
    public var port: Int
    public var username: String
    public var authentication: Authentication
    /// Remote base directory for the music library: absolute, or relative to
    /// the login directory (a leading "~/" is accepted and stripped).
    public var remotePath: String

    public enum Authentication: Sendable, Codable, Equatable {
        /// Password is stored in the Keychain under host/port/username.
        case password
        /// OpenSSH private key file (optionally passphrase-protected; the
        /// passphrase, if any, is stored in the Keychain).
        case privateKeyFile(path: String)
    }

    public init(
        host: String,
        port: Int = 22,
        username: String,
        authentication: Authentication = .password,
        remotePath: String
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.authentication = authentication
        self.remotePath = remotePath
    }

    public var keychainAccount: String {
        "\(username)@\(host):\(port)"
    }
}
