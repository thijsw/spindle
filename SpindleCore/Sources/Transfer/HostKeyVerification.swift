import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH

/// Persistent store of trusted SSH host-key fingerprints, keyed by host:port.
///
/// Spindle pins a server's key on the first successful connection
/// (trust-on-first-use); every later connection must present the same key.
public protocol HostKeyStore: Sendable {
    func pinnedFingerprint(host: String, port: Int) -> String?
    func pin(fingerprint: String, host: String, port: Int)
    func removePin(host: String, port: Int)
}

/// Default `HostKeyStore` backed by the login Keychain. Fingerprints aren't
/// secret, but the Keychain is a convenient per-user store that already holds
/// the matching SFTP password.
public struct KeychainHostKeyStore: HostKeyStore {
    public init() {}

    private func account(_ host: String, _ port: Int) -> String {
        "ssh-hostkey:\(host):\(port)"
    }

    public func pinnedFingerprint(host: String, port: Int) -> String? {
        KeychainStore.load(account: account(host, port))
    }

    public func pin(fingerprint: String, host: String, port: Int) {
        try? KeychainStore.save(secret: fingerprint, account: account(host, port))
    }

    public func removePin(host: String, port: Int) {
        KeychainStore.delete(account: account(host, port))
    }
}

/// The SHA-256 fingerprint of an SSH public key, in the `SHA256:<base64>` form
/// OpenSSH prints (unpadded base64 of the digest of the wire-format key).
public func sshHostKeyFingerprint(_ key: NIOSSHPublicKey) -> String {
    var buffer = ByteBufferAllocator().buffer(capacity: 256)
    _ = key.write(to: &buffer)
    let digest = SHA256.hash(data: Data(buffer.readableBytesView))
    let base64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    return "SHA256:\(base64)"
}

/// Trust-on-first-use host-key validator. On the first connection to a host the
/// presented key is pinned and accepted; afterwards a different key fails the
/// handshake (a changed key can mean a man-in-the-middle).
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    private let host: String
    private let port: Int
    private let store: HostKeyStore

    private let lock = NSLock()
    private var mismatch: DestinationError?

    init(host: String, port: Int, store: HostKeyStore) {
        self.host = host
        self.port = port
        self.store = store
    }

    /// The rejection, if the last validation refused a changed key. Read after
    /// `SSHClient.connect` throws so the precise error survives any NIO wrapping.
    var recordedMismatch: DestinationError? {
        lock.lock(); defer { lock.unlock() }
        return mismatch
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = sshHostKeyFingerprint(hostKey)
        guard let pinned = store.pinnedFingerprint(host: host, port: port) else {
            // First contact: pin this key and trust it.
            store.pin(fingerprint: presented, host: host, port: port)
            validationCompletePromise.succeed(())
            return
        }
        if pinned == presented {
            validationCompletePromise.succeed(())
        } else {
            let error = DestinationError.hostKeyMismatch(host: host, expected: pinned, actual: presented)
            lock.lock(); mismatch = error; lock.unlock()
            validationCompletePromise.fail(error)
        }
    }
}
