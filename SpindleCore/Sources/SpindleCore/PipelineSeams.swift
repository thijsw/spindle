import DiscDrive
import Foundation
import Metadata
import Transfer

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
public actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(value: Int) {
        self.available = value
    }

    public func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            available += 1
        }
    }
}
