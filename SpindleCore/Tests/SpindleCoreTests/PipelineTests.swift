import DiscDrive
import Foundation
import Metadata
import RipEngine
@testable import SpindleCore
import Testing
import Transfer
import Verification
import os

// MARK: Mocks

/// Synthetic full-TOC bytes for a 2-track, 400-sector audio disc.
private func makePipelineTOCData() -> Data {
    makeFullTOC(descriptors: [
        tocDescriptor(session: 1, control: 0, point: 1, lba: 0),
        tocDescriptor(session: 1, control: 0, point: 2, lba: 150),
        tocDescriptor(session: 1, control: 0, point: 0xA2, lba: 400),
    ])
}

private final class MockDriveController: DriveControlling, Sendable {
    private struct State {
        var held: Set<String> = []
        var ejected: [String] = []
    }

    let driveEvents: AsyncStream<DriveEvent>
    private let continuation: AsyncStream<DriveEvent>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {
        (driveEvents, continuation) = AsyncStream.makeStream(of: DriveEvent.self)
    }

    func insert(_ bsdName: String) {
        continuation.yield(.discAppeared(bsdName: bsdName))
    }

    func presentDiscs() -> [String] { [] }

    func hold(bsdName: String) async throws {
        state.withLock { _ = $0.held.insert(bsdName) }
    }

    func release(bsdName: String) {
        state.withLock { _ = $0.held.remove(bsdName) }
    }

    func eject(bsdName: String) async throws {
        state.withLock { $0.ejected.append(bsdName) }
    }

    var ejectedDiscs: [String] {
        state.withLock { $0.ejected }
    }
}

private struct MockMetadata: MetadataProviding {
    let releases: [MBRelease]
    /// Report the releases as a fuzzy TOC match instead of a DiscID hit.
    var fuzzy = false
    /// Simulated network latency, to control which stage reaches the
    /// metadata gate first.
    var delay: Duration?

    func lookup(disc: DiscTOC) async throws -> DiscLookupResult {
        if let delay { try await Task.sleep(for: delay) }
        if releases.isEmpty { return .none }
        return fuzzy ? .fuzzy(releases) : .matched(releases)
    }
}

private struct MockArt: ArtProviding {
    /// Returned for any release that has an MBID; nil = "no art found".
    var art: CoverArt?

    func fetchArt(
        releaseMBID: String?, releaseGroupMBID: String?, fallbackQuery: String?, size: CoverArtSize
    ) async -> CoverArt? {
        releaseMBID == nil ? nil : art
    }
}

private let mockArt = CoverArt(data: Data(repeating: 0xAB, count: 2048), mimeType: "image/jpeg", source: .coverArtArchive)

private struct MockVerifier: RipVerifier {
    func verify(
        toc: TOC, trackChecksums: [Int: TrackChecksums], ctdbDiscCRC32: UInt32?
    ) async throws -> VerificationResult {
        CTDBVerifier.match(
            entries: [],
            audioTrackNumbers: toc.audioTracks.map(\.number),
            trackChecksums: trackChecksums,
            ctdbDiscCRC32: ctdbDiscCRC32
        )
    }
}

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

// MARK: Harness

private struct PipelineHarness {
    let coordinator: PipelineCoordinator
    let drive: MockDriveController
    let library: URL
    let base: URL

    init(
        releases: [MBRelease],
        autoPick: Bool = true,
        unmatchedDiscPolicy: Preferences.UnmatchedDiscPolicy = .tagAsUnknown,
        fuzzy: Bool = false,
        lookupDelay: Duration? = nil,
        art: CoverArt? = nil
    ) throws {
        let base = try makeTempDir()
        self.base = base
        self.library = base.appendingPathComponent("library")
        self.drive = MockDriveController()

        var preferences = Preferences()
        preferences.destination = .localFolder(path: library.path)
        preferences.ripMode = .fast
        preferences.autoPickRelease = autoPick
        preferences.unmatchedDiscPolicy = unmatchedDiscPolicy

        let tocData = makePipelineTOCData()
        let dependencies = PipelineCoordinator.Dependencies(
            drive: drive,
            deviceFactory: { _ in MockCDDevice(leadOut: 400, tocData: tocData) },
            metadata: MockMetadata(releases: releases, fuzzy: fuzzy, delay: lookupDelay),
            art: MockArt(art: art),
            verifier: MockVerifier(),
            destinationFactory: { config in
                guard case .localFolder(let path) = config else { fatalError() }
                return LocalFolderDestination(path: path)
            },
            stagingRoot: base.appendingPathComponent("staging")
        )
        self.coordinator = PipelineCoordinator(
            preferences: preferences,
            dependencies: dependencies,
            jobStore: JobStore(directory: base.appendingPathComponent("store"))
        )
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    /// Consumes pipeline events until the predicate matches or a timeout hits.
    func waitForEvent(
        timeout: Duration = .seconds(30),
        until predicate: @escaping @Sendable (PipelineEvent) -> Bool
    ) async -> PipelineEvent? {
        let events = coordinator.events
        return await withTaskGroup(of: PipelineEvent?.self) { group in
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

    func waitForCompletion(timeout: Duration = .seconds(30)) async -> Bool {
        await waitForEvent(timeout: timeout) { event in
            if case .jobUpdated(let snapshot) = event, snapshot.stage == .completed { return true }
            return false
        } != nil
    }

    /// Counts distinct jobs reaching `.completed` until `count` is seen.
    func waitForCompletions(count: Int, timeout: Duration = .seconds(60)) async -> Int {
        let events = coordinator.events
        return await withTaskGroup(of: Int.self) { group in
            group.addTask {
                var done = Set<JobID>()
                for await event in events {
                    if case .jobUpdated(let snapshot) = event, snapshot.stage == .completed {
                        done.insert(snapshot.id)
                        if done.count >= count { return done.count }
                    }
                }
                return done.count
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return -1
            }
            let first = await group.next() ?? 0
            group.cancelAll()
            return first
        }
    }
}

// MARK: Tests

@Suite struct PipelineTests {
    @Test func singleMatchEndToEnd() async throws {
        let harness = try PipelineHarness(releases: mockReleases(count: 1))
        defer { harness.tearDown() }

        await harness.coordinator.start()
        harness.drive.insert("mockdisk")

        #expect(await harness.waitForCompletion(), "job reaches completed")

        let albumDir = harness.library.appendingPathComponent("Pipeline Artist/Pipeline Album 1 (2001)")
        #expect(FileManager.default.fileExists(atPath: albumDir.appendingPathComponent("01 - Opening.flac").path))
        #expect(FileManager.default.fileExists(atPath: albumDir.appendingPathComponent("02 - Closing.flac").path))
        #expect(harness.drive.ejectedDiscs == ["mockdisk"], "disc ejected after rip")

        let logURL = albumDir.appendingPathComponent("Pipeline Artist - Pipeline Album 1.log")
        let log = try String(contentsOf: logURL, encoding: .utf8)
        #expect(log.contains("rip log"))
        #expect(log.contains("Album        : Pipeline Artist — Pipeline Album 1"))

        let cueURL = albumDir.appendingPathComponent("Pipeline Artist - Pipeline Album 1.cue")
        let cue = try String(contentsOf: cueURL, encoding: .utf8)
        #expect(cue.contains(#"FILE "01 - Opening.flac" WAVE"#))
        #expect(cue.contains("  TRACK 02 AUDIO"))

        let history = await harness.coordinator.history()
        #expect(history.first?.album == "Pipeline Album 1")
        #expect(history.first?.succeeded == true)
    }

    @Test func ambiguousReleaseWaitsForUser() async throws {
        let harness = try PipelineHarness(releases: mockReleases(count: 3), autoPick: false)
        defer { harness.tearDown() }

        await harness.coordinator.start()
        harness.drive.insert("mockdisk")

        let choiceEvent = await harness.waitForEvent { event in
            if case .releaseChoiceNeeded = event { return true }
            return false
        }
        guard case .releaseChoiceNeeded(let jobID)? = choiceEvent else {
            Issue.record("picker was not requested for ambiguous matches")
            return
        }

        await harness.coordinator.chooseRelease(jobID: jobID, candidateID: "REL-2")
        #expect(await harness.waitForCompletion(), "job completes after user choice")
        #expect(
            FileManager.default.fileExists(
                atPath: harness.library
                    .appendingPathComponent("Pipeline Artist/Pipeline Album 2 (2001)/01 - Opening.flac").path
            ),
            "chosen release (not the top-ranked) used for tagging"
        )
    }

    /// Regression: identify() and the processing stage both wait for the
    /// album choice. With a single continuation slot the second waiter
    /// overwrote the first, so art was never fetched after a manual pick.
    @Test func artArrivesAfterManualChoice() async throws {
        let harness = try PipelineHarness(releases: mockReleases(count: 3), autoPick: false, art: mockArt)
        defer { harness.tearDown() }

        await harness.coordinator.start()
        harness.drive.insert("mockdisk")

        // Make sure BOTH stages are parked at the gate before answering:
        // the picker request (identify) and the rip finishing (processing).
        guard case .releaseChoiceNeeded(let jobID)? = await harness.waitForEvent(until: { event in
            if case .releaseChoiceNeeded = event { return true }
            return false
        }) else {
            Issue.record("picker was not requested")
            return
        }
        let parked = await harness.waitForEvent { event in
            if case .jobUpdated(let snapshot) = event, snapshot.stage == .awaitingMetadata { return true }
            return false
        }
        #expect(parked != nil, "rip finished and the job waits for metadata")

        await harness.coordinator.chooseRelease(jobID: jobID, candidateID: "REL-2")

        let artEvent = await harness.waitForEvent(timeout: .seconds(10)) { event in
            if case .artLoaded(let id, _) = event { return id == jobID }
            return false
        }
        #expect(artEvent != nil, "cover art is fetched for the chosen release")
        #expect(await harness.waitForCompletion(), "and the job still completes")
    }

    /// Regression (the other order): when the lookup is slower than the
    /// rip, the processing stage reaches the gate first; the picker answer
    /// must still wake it instead of leaving the job in awaitingMetadata.
    @Test func slowLookupDoesNotStrandTheJob() async throws {
        let harness = try PipelineHarness(
            releases: mockReleases(count: 3), autoPick: false, lookupDelay: .milliseconds(800)
        )
        defer { harness.tearDown() }

        await harness.coordinator.start()
        harness.drive.insert("mockdisk")

        guard case .releaseChoiceNeeded(let jobID)? = await harness.waitForEvent(until: { event in
            if case .releaseChoiceNeeded = event { return true }
            return false
        }) else {
            Issue.record("picker was not requested")
            return
        }
        await harness.coordinator.chooseRelease(jobID: jobID, candidateID: "REL-1")
        #expect(await harness.waitForCompletion(timeout: .seconds(15)), "job completes after the late choice")
    }

    /// A lone *fuzzy* (TOC search) hit is only a guess: with auto-pick off it
    /// must go through the picker like any other candidate list.
    @Test func singleFuzzyMatchRespectsAutoPickSetting() async throws {
        let harness = try PipelineHarness(releases: mockReleases(count: 1), autoPick: false, fuzzy: true)
        defer { harness.tearDown() }

        await harness.coordinator.start()
        harness.drive.insert("mockdisk")

        let event = await harness.waitForEvent(timeout: .seconds(10)) { event in
            if case .releaseChoiceNeeded = event { return true }
            return false
        }
        #expect(event != nil, "fuzzy single match asks the user when auto-pick is off")
    }

    @Test func newDiscDuringUploadIsPickedUp() async throws {
        let harness = try PipelineHarness(releases: mockReleases(count: 1))
        defer { harness.tearDown() }

        await harness.coordinator.start()
        harness.drive.insert("mockdisk")

        // Wait until the first disc is uploading: with eject-after-rip it has
        // already left the drive, yet its job is still non-terminal. That is
        // the exact window where a freshly inserted disc on the same bsdName
        // used to be silently dropped by the dedup guard.
        let uploading = await harness.waitForEvent { event in
            if case .jobUpdated(let snapshot) = event, snapshot.stage == .transferring { return true }
            return false
        }
        #expect(uploading != nil, "first disc reaches the transfer stage")

        // Insert a new disc into the same drive (same bsdName) mid-upload.
        harness.drive.insert("mockdisk")

        let completed = await harness.waitForCompletions(count: 2)
        #expect(completed == 2, "both discs were processed; the second was not dropped")
        #expect(harness.drive.ejectedDiscs.count == 2, "both discs ejected")
    }

    @Test func noMatchesFallsBackToUnknown() async throws {
        let harness = try PipelineHarness(releases: [])
        defer { harness.tearDown() }

        await harness.coordinator.start()
        harness.drive.insert("mockdisk")

        #expect(await harness.waitForCompletion(), "job completes without metadata")
        let contents = (try? FileManager.default.subpathsOfDirectory(atPath: harness.library.path)) ?? []
        #expect(
            contents.contains { $0.hasSuffix(".flac") && $0.contains("Unknown Album") },
            "files land under Unknown Album fallback"
        )
    }

    @Test func unknownDiscPausesForManualTags() async throws {
        let harness = try PipelineHarness(releases: [], unmatchedDiscPolicy: .askForTags)
        defer { harness.tearDown() }

        await harness.coordinator.start()
        harness.drive.insert("mockdisk")

        let event = await harness.waitForEvent { event in
            if case .tagsNeeded = event { return true }
            return false
        }
        guard case .tagsNeeded(let jobID)? = event else {
            Issue.record("tags were not requested for the unknown disc")
            return
        }

        // The draft starts from the fallback (no CD-TEXT in the mock).
        var album = try #require(await harness.coordinator.tagEditorDraft(jobID: jobID, candidateID: nil))
        #expect(album.albumArtist == "Unknown Artist")
        #expect(album.tracks.count == 2)

        album.albumArtist = "Hand Artist"
        album.album = "Hand Album"
        album.date = "1999"
        album.tracks[0].title = "Edited Opening"
        for index in album.tracks.indices { album.tracks[index].artist = "Hand Artist" }
        await harness.coordinator.provideTags(jobID: jobID, album: album)

        #expect(await harness.waitForCompletion(), "job completes after manual tags")
        #expect(
            FileManager.default.fileExists(
                atPath: harness.library
                    .appendingPathComponent("Hand Artist/Hand Album (1999)/01 - Edited Opening.flac").path
            ),
            "hand-edited tags drive the file names"
        )
    }
}
