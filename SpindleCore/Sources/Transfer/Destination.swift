import Foundation

public struct TransferProgress: Sendable {
    public let bytesSent: Int64
    public let totalBytes: Int64

    public var fraction: Double {
        totalBytes > 0 ? Double(bytesSent) / Double(totalBytes) : 0
    }
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

    public var description: String {
        switch self {
        case .notWritable(let path): "Destination is not writable: \(path)"
        case .connectionFailed(let reason): "Connection failed: \(reason)"
        case .uploadFailed(let path, let reason): "Upload of \(path) failed: \(reason)"
        case .missingCredentials(let account): "No saved credentials for \(account)"
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

public struct SFTPConfig: Sendable, Codable, Equatable {
    public var host: String
    public var port: Int
    public var username: String
    public var authentication: Authentication
    /// Remote base directory for the music library (absolute or ~-relative).
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
