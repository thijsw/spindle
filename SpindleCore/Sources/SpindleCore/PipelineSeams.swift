import DiscDrive
import Foundation
import Metadata
import Transfer
import os

// Dependency seams so the whole pipeline runs against mocks in tests.

public protocol MetadataProviding: Sendable {
    func lookup(disc: DiscTOC) async throws -> DiscLookupResult
}

extension MusicBrainzClient: MetadataProviding {}

public protocol ArtProviding: Sendable {
    func fetchArt(
        releaseMBID: String?,
        releaseGroupMBID: String?,
        fallbackQuery: String?,
        size: CoverArtSize
    ) async -> CoverArt?
}

extension CoverArtClient: ArtProviding {}

/// Drive eventing and control (DiskArbitration in production).
public protocol DriveControlling: Sendable {
    var driveEvents: AsyncStream<DriveEvent> { get }
    func presentDiscs() -> [String]
    func hold(bsdName: String) async throws
    func release(bsdName: String)
    func eject(bsdName: String) async throws
}

/// Production drive controller backed by DiskArbitration + IOKit.
public final class SystemDriveController: DriveControlling, @unchecked Sendable {
    private let monitor: DriveMonitor

    public init() throws {
        self.monitor = try DriveMonitor()
    }

    public var driveEvents: AsyncStream<DriveEvent> { monitor.events }

    public func presentDiscs() -> [String] {
        DiscEnumerator.presentCDMedia()
    }

    public func hold(bsdName: String) async throws {
        try await monitor.hold(bsdName: bsdName)
    }

    public func release(bsdName: String) {
        monitor.release(bsdName: bsdName)
    }

    public func eject(bsdName: String) async throws {
        try await monitor.eject(bsdName: bsdName)
    }
}

/// Small counting semaphore for bounding encode/transfer concurrency.
/// `signal()` is synchronous so a `defer` can release the slot without an
/// extra task hop.
public final class AsyncSemaphore: Sendable {
    private struct State {
        var available: Int
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(value: Int) {
        self.state = OSAllocatedUnfairLock(initialState: State(available: value))
    }

    public func wait() async {
        let acquired = state.withLock { state -> Bool in
            guard state.available > 0 else { return false }
            state.available -= 1
            return true
        }
        if acquired { return }
        await withCheckedContinuation { continuation in
            // Re-check under the lock: a signal may have landed in between.
            let resumeNow = state.withLock { state -> Bool in
                if state.available > 0 {
                    state.available -= 1
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    public func signal() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiters.isEmpty else {
                state.available += 1
                return nil
            }
            return state.waiters.removeFirst()
        }
        next?.resume()
    }
}
