import Foundation

/// Per-track drive-state tracker: the wall-clock budget, the one-time speed
/// reduction on struggling media, and the running C2 flag rate.
actor RipHealth {
    private(set) var slowed = false
    private var c2SectorsSeen = 0
    private var c2SectorsFlagged = 0
    private let deadline: ContinuousClock.Instant?

    init(deadline: ContinuousClock.Instant?) {
        self.deadline = deadline
    }

    /// Throws when the track's wall-clock budget is exhausted. Checked
    /// between device contacts; a single in-flight ioctl can't be
    /// interrupted, so the budget is best-effort by one contact.
    func checkDeadline() throws {
        if let deadline, ContinuousClock.now > deadline {
            throw RipError.trackTimeLimitExceeded
        }
    }

    /// True the first time a struggle is reported (caller then slows the drive).
    func noteStruggle() -> Bool {
        if slowed { return false }
        slowed = true
        return true
    }

    /// Tracks the C2 flag rate. A working drive flags a tiny fraction of
    /// sectors even on a bad disc; whole-chunk flagging means the drive is
    /// lying (one-shot probes can't catch intermittent liars). Returns true
    /// when C2 should no longer be believed.
    func noteC2(flagged: Int, of count: Int) -> Bool {
        c2SectorsSeen += count
        c2SectorsFlagged += flagged
        return c2SectorsSeen >= 150 && c2SectorsFlagged * 20 > c2SectorsSeen
    }
}
