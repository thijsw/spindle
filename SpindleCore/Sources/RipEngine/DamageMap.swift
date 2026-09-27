import Foundation

/// Confirmed-unreadable runs (absolute LBA ranges), shared across all tracks
/// and passes of one disc operation: a failing read costs the drive's full
/// internal retry storm, so damage charted once must never be probed again —
/// not by the next chunk, not by the second compare pass, not by the
/// verify-first secure re-rip.
public actor DamageMap {
    private var runs: [Range<Int>] = []

    public init() {}

    func recordBadRun(_ run: Range<Int>) {
        guard !run.isEmpty else { return }
        runs.append(run)
    }

    /// Known-bad runs overlapping `range`, clipped to it and sorted.
    func knownBadRuns(intersecting range: Range<Int>) -> [Range<Int>] {
        runs.compactMap { run in
            let overlap = run.clamped(to: range)
            return overlap.isEmpty ? nil : overlap
        }.sorted { $0.lowerBound < $1.lowerBound }
    }
}
