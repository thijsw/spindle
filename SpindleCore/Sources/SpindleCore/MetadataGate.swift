import Foundation
import Metadata

/// The point where a job's tagging metadata becomes known.
///
/// Identification (which then fetches cover art) and the post-rip processing
/// stage both wait here; the auto-picker, the release picker, the tag editor
/// or the fallback path settles it exactly once, and *every* waiter is
/// resumed. Cancelling releases the waiters with nil when a job fails before
/// its album is known, so no stage is left suspended forever.
///
/// Owned and accessed only inside the `PipelineCoordinator` actor; the
/// `isolation` parameter keeps `wait()` on the caller's executor so the
/// non-Sendable state never crosses an isolation boundary.
final class MetadataGate {
    private(set) var album: ResolvedAlbum?
    private(set) var isCancelled = false
    private var waiters: [CheckedContinuation<ResolvedAlbum?, Never>] = []

    var isSettled: Bool { album != nil || isCancelled }

    /// The resolved album, or nil once the job was cancelled.
    func wait(isolation: isolated (any Actor)? = #isolation) async -> ResolvedAlbum? {
        if let album { return album }
        if isCancelled { return nil }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func resolve(_ album: ResolvedAlbum) {
        guard !isSettled else { return }
        self.album = album
        settle(with: album)
    }

    func cancel() {
        guard !isSettled else { return }
        isCancelled = true
        settle(with: nil)
    }

    private func settle(with value: ResolvedAlbum?) {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: value)
        }
    }
}
