import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing

@testable import Transfer

private let keyAlpha = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDTeSEMdPi1OnHj3rKSZzL+MaXZf5V6ZdhM1rl5eiZ7g spindle-test-1"
private let keyBravo = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO+L+pAqi2Z5zX73OBCWhALVS0dwsc9OMcs4sYdyxYTe spindle-test-2"

/// In-memory pin store so tests never touch the real Keychain.
private final class MemoryHostKeyStore: HostKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var pins: [String: String] = [:]

    private func key(_ host: String, _ port: Int) -> String { "\(host):\(port)" }

    func pinnedFingerprint(host: String, port: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return pins[key(host, port)]
    }

    func pin(fingerprint: String, host: String, port: Int) {
        lock.lock(); defer { lock.unlock() }
        pins[key(host, port)] = fingerprint
    }

    func removePin(host: String, port: Int) {
        lock.lock(); defer { lock.unlock() }
        pins[key(host, port)] = nil
    }
}

/// Drives the validator synchronously through an embedded loop and returns the
/// thrown error, if any.
private func validate(
    _ validator: TOFUHostKeyValidator,
    _ key: NIOSSHPublicKey,
    on loop: EmbeddedEventLoop
) -> Error? {
    let promise = loop.makePromise(of: Void.self)
    var outcome: Result<Void, Error>?
    promise.futureResult.whenComplete { outcome = $0 }
    validator.validateHostKey(hostKey: key, validationCompletePromise: promise)
    loop.run()
    if case .failure(let error) = outcome { return error }
    return nil
}

@Suite struct HostKeyVerificationTests {
    @Test func pinsOnFirstUseThenRequiresTheSameKey() throws {
        let alpha = try NIOSSHPublicKey(openSSHPublicKey: keyAlpha)
        let bravo = try NIOSSHPublicKey(openSSHPublicKey: keyBravo)
        let store = MemoryHostKeyStore()
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }

        // First contact: nothing pinned, so the key is trusted and recorded.
        #expect(store.pinnedFingerprint(host: "nas", port: 22) == nil)
        let validator = TOFUHostKeyValidator(host: "nas", port: 22, store: store)
        #expect(validate(validator, alpha, on: loop) == nil)
        #expect(store.pinnedFingerprint(host: "nas", port: 22) == sshHostKeyFingerprint(alpha))

        // A fresh connection presenting the same key is accepted.
        let again = TOFUHostKeyValidator(host: "nas", port: 22, store: store)
        #expect(validate(again, alpha, on: loop) == nil)

        // A different key is refused with a precise mismatch error.
        let attacker = TOFUHostKeyValidator(host: "nas", port: 22, store: store)
        let error = validate(attacker, bravo, on: loop)
        guard case .hostKeyMismatch(let host, let expected, let actual)? = error as? DestinationError else {
            Issue.record("expected a hostKeyMismatch, got \(String(describing: error))")
            return
        }
        #expect(host == "nas")
        #expect(expected == sshHostKeyFingerprint(alpha))
        #expect(actual == sshHostKeyFingerprint(bravo))
        #expect(attacker.recordedMismatch != nil)
        // The original pin is left intact — a changed key never overwrites it.
        #expect(store.pinnedFingerprint(host: "nas", port: 22) == sshHostKeyFingerprint(alpha))
    }

    @Test func forgettingThePinAllowsANewKey() throws {
        let alpha = try NIOSSHPublicKey(openSSHPublicKey: keyAlpha)
        let bravo = try NIOSSHPublicKey(openSSHPublicKey: keyBravo)
        let store = MemoryHostKeyStore()
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }

        store.pin(fingerprint: sshHostKeyFingerprint(alpha), host: "nas", port: 22)
        store.removePin(host: "nas", port: 22)

        // After forgetting, the next key seen is trusted on first use again.
        let validator = TOFUHostKeyValidator(host: "nas", port: 22, store: store)
        #expect(validate(validator, bravo, on: loop) == nil)
        #expect(store.pinnedFingerprint(host: "nas", port: 22) == sshHostKeyFingerprint(bravo))
    }

    @Test func fingerprintIsStableAndKeySpecific() throws {
        let alpha = try NIOSSHPublicKey(openSSHPublicKey: keyAlpha)
        let bravo = try NIOSSHPublicKey(openSSHPublicKey: keyBravo)
        #expect(sshHostKeyFingerprint(alpha) == sshHostKeyFingerprint(alpha))
        #expect(sshHostKeyFingerprint(alpha) != sshHostKeyFingerprint(bravo))
        #expect(sshHostKeyFingerprint(alpha).hasPrefix("SHA256:"))
    }
}
