import Foundation

/// Smoothed throughput estimate for one transfer, fed with cumulative byte
/// counts. Progress callbacks arrive through independent tasks and can land
/// out of order; a sample that moves backwards is rejected rather than
/// producing a negative rate.
struct TransferRateEstimator: Sendable {
    private var lastBytes: Int64 = 0
    private var lastTime: ContinuousClock.Instant?
    private(set) var bytesPerSecond: Double = 0

    /// Records a cumulative byte count. Returns false when the sample is
    /// stale (fewer bytes than an earlier sample) and should be ignored.
    mutating func record(bytes: Int64, at now: ContinuousClock.Instant = .now) -> Bool {
        guard let lastTime else {
            self.lastTime = now
            lastBytes = bytes
            return true
        }
        guard bytes >= lastBytes else { return false }
        let elapsed = (now - lastTime) / .seconds(1)
        // Sub-50 ms ticks: jitter swamps the estimate, so accumulate instead.
        guard elapsed > 0.05 else { return true }
        let instant = Double(bytes - lastBytes) / elapsed
        bytesPerSecond = bytesPerSecond == 0 ? instant : bytesPerSecond * 0.7 + instant * 0.3
        self.lastTime = now
        lastBytes = bytes
        return true
    }
}
