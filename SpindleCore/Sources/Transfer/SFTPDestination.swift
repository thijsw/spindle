import Citadel
import Crypto
import Foundation
import NIOCore

/// Uploads to a remote server over SFTP (Citadel/SwiftNIO SSH).
public actor SFTPDestination: Destination {
    private let config: SFTPConfig
    private let secret: String? // password or key passphrase, from Keychain
    private let hostKeyStore: HostKeyStore
    private var client: SSHClient?
    private var sftp: SFTPClient?
    private var createdDirectories: Set<String> = []

    private static let chunkSize = 1 << 20

    public init(config: SFTPConfig, secret: String?, hostKeyStore: HostKeyStore = KeychainHostKeyStore()) {
        self.config = config
        self.secret = secret
        self.hostKeyStore = hostKeyStore
    }

    public init(config: SFTPConfig) {
        self.init(config: config, secret: KeychainStore.load(account: config.keychainAccount))
    }

    // MARK: Connection

    private func authenticationMethod() throws -> SSHAuthenticationMethod {
        switch config.authentication {
        case .password:
            guard let secret else {
                throw DestinationError.missingCredentials(config.keychainAccount)
            }
            return .passwordBased(username: config.username, password: secret)

        case .privateKeyFile(let path):
            let expanded = (path as NSString).expandingTildeInPath
            guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else {
                throw DestinationError.connectionFailed("cannot read key file \(path)")
            }
            if let key = try? Curve25519.Signing.PrivateKey(
                sshEd25519: text, decryptionKey: secret.map { Data($0.utf8) }
            ) {
                return .ed25519(username: config.username, privateKey: key)
            }
            if let key = try? Insecure.RSA.PrivateKey(
                sshRsa: text, decryptionKey: secret.map { Data($0.utf8) }
            ) {
                return .rsa(username: config.username, privateKey: key)
            }
            throw DestinationError.connectionFailed(
                "unsupported key format in \(path) (Ed25519 and RSA OpenSSH keys are supported)"
            )
        }
    }

    private func connectedSFTP() async throws -> SFTPClient {
        if let sftp, sftp.isActive { return sftp }

        client = nil
        sftp = nil
        createdDirectories.removeAll()

        let validator = TOFUHostKeyValidator(host: config.host, port: config.port, store: hostKeyStore)
        do {
            let client = try await SSHClient.connect(
                host: config.host,
                port: config.port,
                authenticationMethod: authenticationMethod(),
                hostKeyValidator: .custom(validator),
                reconnect: .never
            )
            let sftp = try await client.openSFTP()
            self.client = client
            self.sftp = sftp
            return sftp
        } catch let error as DestinationError {
            throw error
        } catch {
            // A rejected host key surfaces here; report it precisely rather than
            // as a generic connection failure.
            if let mismatch = validator.recordedMismatch { throw mismatch }
            throw DestinationError.connectionFailed(String(describing: error))
        }
    }

    private func remotePath(_ relative: String) -> String {
        let base = config.remotePath.hasSuffix("/") ? String(config.remotePath.dropLast()) : config.remotePath
        return "\(base)/\(relative)"
    }

    private func ensureDirectory(_ path: String, sftp: SFTPClient) async throws {
        var current = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            current += (current.isEmpty && !path.hasPrefix("/") ? "" : "/") + component
            guard !createdDirectories.contains(current) else { continue }
            // mkdir fails when the directory exists; treat that as success.
            try? await sftp.createDirectory(atPath: current)
            createdDirectories.insert(current)
        }
    }

    // MARK: Destination

    public func prepare() async throws {
        let sftp = try await connectedSFTP()
        try await ensureDirectory(remotePath(""), sftp: sftp)
    }

    public func upload(
        file: URL,
        toRelativePath relativePath: String,
        progress: (@Sendable (TransferProgress) -> Void)?
    ) async throws {
        var lastError: Error?
        for attempt in 0 ..< 3 {
            if attempt > 0 {
                try await Task.sleep(for: .seconds(Double(attempt) * 2))
            }
            do {
                try await uploadOnce(file: file, toRelativePath: relativePath, progress: progress)
                return
            } catch {
                lastError = error
                // Force a fresh connection on the next attempt.
                sftp = nil
                client = nil
            }
        }
        throw DestinationError.uploadFailed(
            path: relativePath,
            reason: String(describing: lastError ?? DestinationError.connectionFailed("unknown"))
        )
    }

    private func uploadOnce(
        file: URL,
        toRelativePath relativePath: String,
        progress: (@Sendable (TransferProgress) -> Void)?
    ) async throws {
        let sftp = try await connectedSFTP()
        let destination = remotePath(relativePath)
        try await ensureDirectory((destination as NSString).deletingLastPathComponent, sftp: sftp)

        guard let input = try? FileHandle(forReadingFrom: file) else {
            throw DestinationError.uploadFailed(path: relativePath, reason: "cannot read source file")
        }
        defer { try? input.close() }
        let totalBytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0

        let partial = destination + ".part"
        let handle = try await sftp.openFile(
            filePath: partial,
            flags: [.write, .create, .truncate]
        )

        do {
            var offset: UInt64 = 0
            while let chunk = try input.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                try await handle.write(ByteBuffer(data: chunk), at: offset)
                offset += UInt64(chunk.count)
                progress?(TransferProgress(bytesSent: Int64(offset), totalBytes: totalBytes))
            }
            try await handle.close()
        } catch {
            try? await handle.close()
            throw error
        }

        // Replace any previous file, then promote the partial.
        try? await sftp.remove(at: destination)
        try await sftp.rename(at: partial, to: destination)
    }

    public func test() async -> Result<String, Error> {
        do {
            let sftp = try await connectedSFTP()
            let base = remotePath("")
            try await ensureDirectory(base, sftp: sftp)
            let probe = remotePath(".spindle-write-test")
            let handle = try await sftp.openFile(filePath: probe, flags: [.write, .create, .truncate])
            try await handle.write(ByteBuffer(string: "ok"), at: 0)
            try await handle.close()
            try? await sftp.remove(at: probe)
            return .success("Connected to \(config.host) — \(base) is writable.")
        } catch {
            return .failure(error)
        }
    }

    public func close() async {
        if let sftp {
            try? await sftp.close()
        }
        if let client {
            try? await client.close()
        }
        sftp = nil
        client = nil
    }
}
