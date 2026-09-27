import Citadel
import Crypto
import Foundation
import NIOCore

/// Uploads to a remote server over SFTP (Citadel/SwiftNIO SSH).
public actor SFTPDestination: Destination {
    private let config: SFTPConfig
    /// Password or key passphrase; nil until loaded (see `secretSource`).
    private var secret: String?
    private let secretSource: @Sendable () -> String?
    private let hostKeyStore: HostKeyStore
    private var client: SSHClient?
    private var sftp: SFTPClient?
    private var createdDirectories: Set<String> = []

    private static let chunkSize = 1 << 20

    public init(config: SFTPConfig, secret: String?, hostKeyStore: HostKeyStore = KeychainHostKeyStore()) {
        self.config = config
        self.secret = secret
        self.secretSource = { nil }
        self.hostKeyStore = hostKeyStore
    }

    /// Reads the secret from the Keychain on first connect, not at
    /// construction: SecItemCopyMatching can block on a Keychain prompt and
    /// must not run on whichever actor builds the destination.
    public init(config: SFTPConfig) {
        self.config = config
        self.secret = nil
        let account = config.keychainAccount
        self.secretSource = { KeychainStore.load(account: account) }
        self.hostKeyStore = KeychainHostKeyStore()
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

        await dropConnection()
        if secret == nil {
            secret = secretSource()
        }

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

    /// Closes and forgets the connection so the next call reconnects.
    private func dropConnection() async {
        if let sftp { try? await sftp.close() }
        if let client { try? await client.close() }
        sftp = nil
        client = nil
        createdDirectories.removeAll()
    }

    /// ".<name>.part" next to the final file.
    static func partialPath(for destination: String) -> String {
        let path = destination as NSString
        let directory = path.deletingLastPathComponent
        let hidden = ".\(path.lastPathComponent).part"
        return directory.isEmpty ? hidden : "\(directory)/\(hidden)"
    }

    private func remotePath(_ relative: String) -> String {
        let base = Self.normalizedBase(config.remotePath)
        return relative.isEmpty ? base : "\(base)/\(relative)"
    }

    /// SFTP has no `~`: relative paths resolve against the login directory,
    /// so "~" becomes "." and "~/music" becomes "music". Trailing slashes
    /// are dropped; empty means the login directory.
    static func normalizedBase(_ path: String) -> String {
        var base = path
        if base == "~" {
            base = "."
        } else if base.hasPrefix("~/") {
            base.removeFirst(2)
        }
        while base.count > 1, base.hasSuffix("/") {
            base.removeLast()
        }
        return base.isEmpty ? "." : base
    }

    private func ensureDirectory(_ path: String, sftp: SFTPClient) async throws {
        var current = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) where component != "." {
            current += (current.isEmpty && !path.hasPrefix("/") ? "" : "/") + component
            guard !createdDirectories.contains(current) else { continue }
            do {
                try await sftp.createDirectory(atPath: current)
            } catch {
                // mkdir fails when the directory already exists — fine. Any
                // other failure (permissions, a file in the way) must surface
                // here rather than as a confusing open/rename error later.
                guard (try? await sftp.getAttributes(at: current)) != nil else {
                    throw DestinationError.connectionFailed(
                        "cannot create remote directory \(current): \(String(describing: error))"
                    )
                }
            }
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
            } catch let error as DestinationError where !error.isTransient {
                // A changed host key or missing password won't fix itself
                // in two seconds, and its precise error must reach the user.
                await dropConnection()
                throw error
            } catch {
                lastError = error
                // Force a fresh connection on the next attempt.
                await dropConnection()
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
        let totalBytes = file.fileSize ?? 0

        // Hidden partial name, like the folder destination, so a library
        // scanner watching the directory never lists a half-written track.
        let partial = Self.partialPath(for: destination)
        let handle = try await sftp.openFile(
            filePath: partial,
            flags: [.write, .create, .truncate]
        )

        do {
            // Keep one write in flight while the next chunk is read and
            // sent, so a WAN round trip doesn't idle the link between chunks.
            var offset: UInt64 = 0
            var inFlight: Task<Void, Error>?
            while let chunk = try input.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                let writeOffset = offset
                let write = Task { try await handle.write(ByteBuffer(data: chunk), at: writeOffset) }
                offset += UInt64(chunk.count)
                if let inFlight {
                    try await inFlight.value
                }
                inFlight = write
                progress?(TransferProgress(bytesSent: Int64(offset), totalBytes: totalBytes))
            }
            if let inFlight {
                try await inFlight.value
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
            try await prepare()
            let sftp = try await connectedSFTP()
            let base = remotePath("")
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
        await dropConnection()
    }
}
