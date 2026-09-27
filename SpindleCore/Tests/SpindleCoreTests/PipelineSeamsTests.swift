import Foundation
import Metadata
import Testing
import os

@testable import SpindleCore

@Suite struct AsyncSemaphoreTests {
    @Test func boundsConcurrencyAndWakesWaitersInOrder() async {
        let semaphore = AsyncSemaphore(value: 1)
        await semaphore.wait()

        let order = OrderLog()
        let waiters = Task {
            await withTaskGroup(of: Void.self) { group in
                for index in 1 ... 3 {
                    group.addTask {
                        await semaphore.wait()
                        order.append(index)
                        semaphore.signal()
                    }
                    try? await Task.sleep(for: .milliseconds(20)) // stagger the arrival order
                }
            }
        }

        try? await Task.sleep(for: .milliseconds(120))
        #expect(order.values.isEmpty, "nobody runs while the single slot is held")
        semaphore.signal()
        await waiters.value
        #expect(order.values == [1, 2, 3], "FIFO hand-off, one at a time")
    }
}

/// Thread-safe append-only log for concurrency tests.
private final class OrderLog: Sendable {
    private let storage = OSAllocatedUnfairLock<[Int]>(initialState: [])
    var values: [Int] { storage.withLock { $0 } }
    func append(_ value: Int) { storage.withLock { $0.append(value) } }
}

@Suite struct TransferRateEstimatorTests {
    @Test func smoothsAndRejectsStaleSamples() {
        var estimator = TransferRateEstimator()
        let start = ContinuousClock.now
        let first = estimator.record(bytes: 0, at: start)
        let second = estimator.record(bytes: 1_000_000, at: start + .seconds(1))
        #expect(first && second)
        #expect(estimator.bytesPerSecond == 1_000_000)
        let stale = estimator.record(bytes: 500_000, at: start + .seconds(1.5))
        #expect(!stale, "a late, smaller sample is ignored")
        let third = estimator.record(bytes: 3_000_000, at: start + .seconds(2))
        #expect(third)
        #expect(estimator.bytesPerSecond > 1_000_000 && estimator.bytesPerSecond < 2_000_000, "EMA moves toward 2 MB/s")
    }
}

@Suite struct ResolutionDecisionTests {
    private func ranked(count: Int, autoPickable: Bool = true) -> [ReleaseScorer.Ranked] {
        let releases = (1 ... count).compactMap { n -> MBRelease? in
            let json = """
            { "id": "REL-\(n)", "title": "Album \(n)", "status": "Official", "date": "2001",
              "media": [ { "position": 1, "format": "CD", "track-count": 2 } ] }
            """
            return try? JSONDecoder().decode(MBRelease.self, from: Data(json.utf8))
        }
        return ReleaseScorer().rank(releases, discID: nil, audioTrackCount: autoPickable ? 2 : 5)
    }

    @Test func loneDiscIDMatchIsTakenEvenWithAutoPickOff() {
        var prefs = Preferences()
        prefs.autoPickRelease = false
        if case .autoPick = PipelineCoordinator.decideResolution(ranked: ranked(count: 1), exactDiscID: true, preferences: prefs) {
        } else {
            Issue.record("a single release attached to the DiscID leaves nothing to choose")
        }
    }

    @Test func loneFuzzyMatchFollowsTheAutoPickSettings() {
        var prefs = Preferences()
        prefs.autoPickRelease = false
        if case .pick = PipelineCoordinator.decideResolution(ranked: ranked(count: 1), exactDiscID: false, preferences: prefs) {
        } else {
            Issue.record("a fuzzy guess must not bypass a disabled auto-pick")
        }
        prefs.autoPickRelease = true
        if case .autoPick = PipelineCoordinator.decideResolution(ranked: ranked(count: 1), exactDiscID: false, preferences: prefs) {
        } else {
            Issue.record("a confident lone fuzzy match auto-picks when allowed")
        }
    }

    @Test func noCandidatesFollowTheUnmatchedPolicy() {
        var prefs = Preferences()
        prefs.unmatchedDiscPolicy = .askForTags
        if case .askForTags = PipelineCoordinator.decideResolution(ranked: [], exactDiscID: false, preferences: prefs) {} else {
            Issue.record("expected askForTags")
        }
        prefs.unmatchedDiscPolicy = .tagAsUnknown
        if case .fallback = PipelineCoordinator.decideResolution(ranked: [], exactDiscID: false, preferences: prefs) {} else {
            Issue.record("expected fallback")
        }
    }

    @Test func closeCallGoesToThePicker() {
        let prefs = Preferences() // auto-pick on, threshold 0.75
        let two = ranked(count: 2) // identical scores → zero gap, low confidence
        if case .pick = PipelineCoordinator.decideResolution(ranked: two, exactDiscID: true, preferences: prefs) {} else {
            Issue.record("two equally good releases must be shown to the user")
        }
    }
}
