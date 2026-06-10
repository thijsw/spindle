import DiscDrive
import Foundation
import Metadata
import SpindleCore
import Transfer
import Verification

// MARK: Mocks

/// Synthetic full-TOC bytes for a 2-track, 400-sector audio disc.
private func makePipelineTOCData() -> Data {
    func descriptor(point: UInt8, lba: Int, control: UInt8 = 0) -> [UInt8] {
        let frames = lba + 150
        return [
            1, 1 << 4 | control, 0, point,
            0, 0, 0, 0,
            UInt8(frames / (60 * 75)), UInt8((frames / 75) % 60), UInt8(frames % 75),
        ]
    }
    let descriptors = [
        descriptor(point: 1, lba: 0),
        descriptor(point: 2, lba: 150),
        descriptor(point: 0xA2, lba: 400),
    ]
    let dataLength = UInt16(2 + descriptors.count * 11)
    var bytes: [UInt8] = [UInt8(dataLength >> 8), UInt8(dataLength & 0xFF), 1, 1]
    for d in descriptors { bytes += d }
    return Data(bytes)
}

private final class MockDriveController: DriveControlling, @unchecked Sendable {
    let driveEvents: AsyncStream<DriveEvent>
    private let continuation: AsyncStream<DriveEvent>.Continuation
    private let lock = NSLock()
    private var held: Set<String> = []
    private(set) var ejected: [String] = []

    init() {
        var continuation: AsyncStream<DriveEvent>.Continuation!
        self.driveEvents = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func insert(_ bsdName: String) {
        continuation.yield(.discAppeared(bsdName: bsdName))
    }

    func presentDiscs() -> [String] { [] }

    func hold(bsdName: String) async throws {
        lock.withLock { _ = held.insert(bsdName) }
    }

    func release(bsdName: String) {
        lock.withLock { _ = held.remove(bsdName) }
    }

    func eject(bsdName: String) async throws {
        lock.withLock { ejected.append(bsdName) }
    }

    var ejectedDiscs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return ejected
    }
}

private struct MockMetadata: MetadataProviding {
    let releases: [MBRelease]

    func lookup(disc: DiscTOC) async throws -> DiscLookupResult {
        releases.isEmpty ? .none : .matched(releases)
    }
}

private struct MockArt: ArtProviding {
    func fetchArt(
        releaseMBID: String?, releaseGroupMBID: String?, fallbackQuery: String?, size: CoverArtSize
    ) async -> CoverArt? {
        nil
    }
}

private struct MockVerifier: RipVerifier {
    func verify(
        toc: TOC, trackChecksums: [Int: RipEngine.TrackChecksums], ctdbDiscCRC32: UInt32?
    ) async throws -> VerificationResult {
        CTDBVerifier.match(
            entries: [],
            audioTrackNumbers: toc.audioTracks.map(\.number),
            trackChecksums: trackChecksums,
            ctdbDiscCRC32: ctdbDiscCRC32
        )
    }
}

import RipEngine

/// Two-track release JSON (so ResolvedAlbum has titles for both tracks).
private func mockReleases(count: Int) -> [MBRelease] {
    let single = """
    {
      "id": "REL-%d",
      "title": "Pipeline Album %d",
      "status": "Official",
      "date": "2001-01-0%d",
      "country": "NL",
      "artist-credit": [ { "name": "Pipeline Artist", "artist": { "id": "ART-1", "name": "Pipeline Artist", "sort-name": "Artist, Pipeline" } } ],
      "media": [ {
        "position": 1, "format": "CD", "track-count": 2,
        "tracks": [
          { "id": "T1-%d", "position": 1, "title": "Opening", "recording": { "id": "R1-%d", "title": "Opening" } },
          { "id": "T2-%d", "position": 2, "title": "Closing", "recording": { "id": "R2-%d", "title": "Closing" } }
        ]
      } ]
    }
    """
    return (1...count).compactMap { n in
        let json = String(format: single, n, n, n, n, n, n, n)
        return try? JSONDecoder().decode(MBRelease.self, from: Data(json.utf8))
    }
}

// MARK: Tests

@MainActor
func pipelineTests() async {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("spindle-pipeline-\(ProcessInfo.processInfo.processIdentifier)")
    defer { try? FileManager.default.removeItem(at: base) }

    func makeCoordinator(
        releases: [MBRelease],
        suffix: String,
        autoPick: Bool = true
    ) -> (PipelineCoordinator, MockDriveController, URL) {
        let library = base.appendingPathComponent("library-\(suffix)")
        let drive = MockDriveController()
        let tocData = makePipelineTOCData()
        var preferences = Preferences()
        preferences.destination = .localFolder(path: library.path)
        preferences.ripMode = .fast
        preferences.autoPickRelease = autoPick
        let dependencies = PipelineCoordinator.Dependencies(
            drive: drive,
            deviceFactory: { _ in MockCDDevice(leadOut: 400, tocData: tocData) },
            metadata: MockMetadata(releases: releases),
            art: MockArt(),
            verifier: MockVerifier(),
            destinationFactory: { config in
                guard case .localFolder(let path) = config else { fatalError() }
                return LocalFolderDestination(path: path)
            },
            stagingRoot: base.appendingPathComponent("staging-\(suffix)")
        )
        let coordinator = PipelineCoordinator(
            preferences: preferences,
            dependencies: dependencies,
            jobStore: JobStore(directory: base.appendingPathComponent("store-\(suffix)"))
        )
        return (coordinator, drive, library)
    }

    /// Consumes pipeline events until the predicate is satisfied or a timeout hits.
    func waitFor(
        _ events: AsyncStream<PipelineEvent>,
        timeout: Duration = .seconds(30),
        until predicate: @escaping @Sendable (PipelineEvent) -> Bool
    ) async -> Bool {
        await waitForEvent(events, timeout: timeout, until: predicate) != nil
    }

    func waitForEvent(
        _ events: AsyncStream<PipelineEvent>,
        timeout: Duration = .seconds(30),
        until predicate: @escaping @Sendable (PipelineEvent) -> Bool
    ) async -> PipelineEvent? {
        await withTaskGroup(of: PipelineEvent?.self) { group in
            group.addTask {
                for await event in events where predicate(event) { return event }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    await Harness.asyncSuite("Pipeline: single match end-to-end") {
        let (coordinator, drive, library) = makeCoordinator(releases: mockReleases(count: 1), suffix: "single")
        let events = coordinator.events
        await coordinator.start()
        drive.insert("mockdisk")

        let completed = await waitFor(events) { event in
            if case .jobUpdated(let snapshot) = event, snapshot.stage == .completed { return true }
            return false
        }
        Harness.expect(completed, "job reaches completed")

        let flac1 = library.appendingPathComponent("Pipeline Artist/Pipeline Album 1 (2001)/01 - Opening.flac")
        let flac2 = library.appendingPathComponent("Pipeline Artist/Pipeline Album 1 (2001)/02 - Closing.flac")
        Harness.expect(FileManager.default.fileExists(atPath: flac1.path), "track 1 delivered to destination")
        Harness.expect(FileManager.default.fileExists(atPath: flac2.path), "track 2 delivered to destination")
        Harness.expect(drive.ejectedDiscs == ["mockdisk"], "disc ejected after rip")

        let history = await coordinator.history()
        Harness.expect(history.first?.album == "Pipeline Album 1" && history.first?.succeeded == true,
                       "history records success")
    }

    await Harness.asyncSuite("Pipeline: ambiguous release waits for the user") {
        let (coordinator, drive, library) = makeCoordinator(
            releases: mockReleases(count: 3), suffix: "multi", autoPick: false
        )
        let events = coordinator.events
        await coordinator.start()
        drive.insert("mockdisk")

        let choiceEvent = await waitForEvent(events) { event in
            if case .releaseChoiceNeeded = event { return true }
            return false
        }
        Harness.expect(choiceEvent != nil, "picker requested for ambiguous matches")

        guard case .releaseChoiceNeeded(let jobID)? = choiceEvent else { return }
        await coordinator.chooseRelease(jobID: jobID, candidateID: "REL-2")

        let completed = await waitFor(events) { event in
            if case .jobUpdated(let snapshot) = event, snapshot.stage == .completed { return true }
            return false
        }
        Harness.expect(completed, "job completes after user choice")
        Harness.expect(
            FileManager.default.fileExists(
                atPath: library.appendingPathComponent("Pipeline Artist/Pipeline Album 2 (2001)/01 - Opening.flac").path
            ),
            "chosen release (not the top-ranked) used for tagging"
        )
    }

    await Harness.asyncSuite("Pipeline: no matches falls back to Unknown") {
        let (coordinator, drive, library) = makeCoordinator(releases: [], suffix: "none")
        let events = coordinator.events
        await coordinator.start()
        drive.insert("mockdisk")

        let completed = await waitFor(events) { event in
            if case .jobUpdated(let snapshot) = event, snapshot.stage == .completed { return true }
            return false
        }
        Harness.expect(completed, "job completes without metadata")
        let contents = (try? FileManager.default.subpathsOfDirectory(atPath: library.path)) ?? []
        Harness.expect(
            contents.contains { $0.hasSuffix(".flac") && $0.contains("Unknown Album") },
            "files land under Unknown Album fallback"
        )
    }
}
