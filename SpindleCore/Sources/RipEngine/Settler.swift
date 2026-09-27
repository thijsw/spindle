import Foundation

/// Outcome of settling one disputed window of audio.
struct SettledData {
    var audio: Data
    var rereads: Int
    /// True when `agreeingPasses` byte-identical clean reads were seen;
    /// false when the effort cap was hit and `audio` is the best guess.
    var recovered: Bool
}

/// Re-reads a disputed window until `agreeingPasses` byte-identical clean
/// candidates agree (cdparanoia/EAC-style voting).
///
/// Drives cache audio reads, and an immediate re-read of the same sectors
/// is served from that cache — identical garbage twice looks "verified".
/// Re-reads are therefore cache-busted, but only when timing shows the
/// previous read actually came from the cache (< 6 ms, cdparanoia's
/// heuristic); a slow read already proves medium access, and busting it
/// would just wear the mechanism. The effort is capped as soon as the drive
/// is visibly struggling: its internal retries dwarf ours.
struct Settler: Sendable {
    let reader: ResilientReader

    /// A read faster than this came from the drive cache (cdparanoia: 6 ms).
    private static let cacheFastThreshold: Duration = .milliseconds(6)
    /// Hard wall-clock budget for settling one window: retries are
    /// pointless once the drive's own retry storms dominate each attempt.
    private static let settleTimeBudget: Duration = .seconds(10)

    /// - Parameters:
    ///   - initialCandidate: a read already in hand (compare mode's second
    ///     pass), counted as one vote.
    ///   - placeholder: returned when nothing could be settled and no
    ///     candidate was ever produced (zero audio of the window's size).
    ///   - flushNear: LBA whose cache neighbourhood to evict before a
    ///     cache-fast re-read.
    ///   - read: one device contact producing a clean candidate, or nil when
    ///     the read failed or the drive flagged it.
    func settle(
        maxRetries: Int,
        agreeingPasses: Int,
        health: RipHealth,
        initialCandidate: Data? = nil,
        placeholder: Data,
        flushNear lba: Int,
        read: () async throws -> Data?
    ) async throws -> SettledData {
        var votes: [Data: Int] = [:]
        if let initialCandidate { votes[initialCandidate] = 1 }
        var rereads = 0
        var effectiveMax = maxRetries
        var previousWasCacheFast = true // the triggering read just cached this window
        let deadline = ContinuousClock.now + Self.settleTimeBudget

        while rereads < effectiveMax, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await health.checkDeadline()
            if previousWasCacheFast {
                await reader.flushCache(near: lba)
            }
            let started = ContinuousClock.now
            let candidate = try await read()
            let elapsed = ContinuousClock.now - started
            rereads += 1
            previousWasCacheFast = elapsed < Self.cacheFastThreshold

            if elapsed > ResilientReader.struggleThreshold {
                effectiveMax = min(effectiveMax, rereads + 1)
                await reader.slowDownOnce(health)
            }

            guard let candidate else { continue } // failed or flagged: retry counts toward the cap
            let count = (votes[candidate] ?? 0) + 1
            votes[candidate] = count
            if count >= agreeingPasses {
                return SettledData(audio: candidate, rereads: rereads, recovered: true)
            }
        }

        let best = votes.max { $0.value < $1.value }?.key ?? placeholder
        return SettledData(audio: best, rereads: rereads, recovered: false)
    }
}
