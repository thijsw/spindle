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

/// Two-track release JSON (so ResolvedAlbum has titles for both tracks).
/// With `discs > 1` our two-track disc is the LAST medium of a multi-disc
/// release (the others carry five dummy tracks).
private func mockReleases(count: Int, discs: Int = 1) -> [MBRelease] {
    func medium(_ position: Int, _ n: Int, ours: Bool) -> String {
        if ours {
            return """
            { "position": \(position), "format": "CD", "track-count": 2,
              "tracks": [
                { "id": "T1-\(n)", "position": 1, "title": "Opening", "recording": { "id": "R1-\(n)", "title": "Opening" } },
                { "id": "T2-\(n)", "position": 2, "title": "Closing", "recording": { "id": "R2-\(n)", "title": "Closing" } }
              ] }
            """
        }
        let tracks = (1 ... 5).map { #"{ "id": "X\#(position)-\#($0)", "position": \#($0), "title": "Other \#($0)" }"# }
        return #"{ "position": \#(position), "format": "CD", "track-count": 5, "tracks": [\#(tracks.joined(separator: ","))] }"#
    }
    return (1 ... count).compactMap { n in
        let media = (1 ... discs).map { medium($0, n, ours: $0 == discs) }
        let json = """
        {
          "id": "REL-\(n)",
          "title": "Pipeline Album \(n)",
          "status": "Official",
          "date": "2001-01-0\(n)",
          "country": "NL",
          "artist-credit": [ { "name": "Pipeline Artist", "artist": { "id": "ART-1", "name": "Pipeline Artist", "sort-name": "Artist, Pipeline" } } ],
          "media": [ \(media.joined(separator: ",")) ]
        }
        """
        return try? JSONDecoder().decode(MBRelease.self, from: Data(json.utf8))
    }
}

// MARK: Harness

/// Consumes the coordinator's single-consumer event stream exactly once and
/// lets tests wait for events with a timeout that never cancels the stream
/// (cancelling a `for await` finishes an AsyncStream for good).
private actor EventRecorder {
    private var events: [PipelineEvent] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var task: Task<Void, Never>?

    func start(_ stream: AsyncStream<PipelineEvent>) {
        task = Task {
            for await event in stream {
                self.record(event)
            }
        }
    }

    private func record(_ event: PipelineEvent) {
        events.append(event)
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    /// First recorded event (from `startIndex` on) matching the predicate,
    /// waiting up to `timeout` for new ones. Returns the event and the
    /// index after it, so a caller can continue from where it left off.
    func first(
        after startIndex: Int,
        timeout: Duration,
        where predicate: @escaping @Sendable (PipelineEvent) -> Bool
    ) async -> (event: PipelineEvent, next: Int)? {
        let deadline = ContinuousClock.now + timeout
        var index = startIndex
        while true {
            while index < events.count {
                let event = events[index]
                index += 1
                if predicate(event) { return (event, index) }
            }
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { return nil }
            let woke = await withTaskGroup(of: Bool.self) { group in
                group.addTask { await self.waitForNewEvent(); return true }
                group.addTask { try? await Task.sleep(for: remaining); return false }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if !woke { return nil }
        }
    }

    private func waitForNewEvent() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    var count: Int { events.count }
}

private struct PipelineHarness {
    let coordinator: PipelineCoordinator
    let drive: MockDriveController
    let library: URL
    let base: URL
    let recorder = EventRecorder()

    init(
        releases: [MBRelease],
        autoPick: Bool = true,
        unmatchedDiscPolicy: Preferences.UnmatchedDiscPolicy = .tagAsUnknown,
        ejectTiming: Preferences.EjectTiming = .afterRip,
        destination: Bool = true,
        fuzzy: Bool = false,
        lookupDelay: Duration? = nil,
        art: CoverArt? = nil,
        deviceFails: Bool = false
    ) throws {
        let base = try makeTempDir()
        self.base = base
        self.library = base.appendingPathComponent("library")
        self.drive = MockDriveController()

        var preferences = Preferences()
        preferences.destination = destination ? .localFolder(path: library.path) : nil
        preferences.ripMode = .fast
        preferences.autoPickRelease = autoPick
        preferences.unmatchedDiscPolicy = unmatchedDiscPolicy
        preferences.ejectTiming = ejectTiming

        struct DeviceUnavailable: Error {}
        let tocData = makePipelineTOCData()
        let dependencies = PipelineCoordinator.Dependencies(
            drive: drive,
            deviceFactory: { _ in
                if deviceFails { throw DeviceUnavailable() }
                return MockCDDevice(leadOut: 400, tocData: tocData)
            },
            metadata: MockMetadata(releases: releases, fuzzy: fuzzy, delay: lookupDelay),
            art: MockArt(art: art),
            verifier: StaticCTDBVerifier(),
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

    /// Starts the coordinator and the event recorder.
    func start() async {
        await recorder.start(coordinator.events)
        await coordinator.start()
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    /// The first not-yet-consumed event matching the predicate, or nil on timeout.
    func waitForEvent(
        timeout: Duration = .seconds(30),
        until predicate: @escaping @Sendable (PipelineEvent) -> Bool
    ) async -> PipelineEvent? {
        guard let (event, next) = await recorder.first(after: cursor.value, timeout: timeout, where: predicate) else {
            return nil
        }
        cursor.value = next
        return event
    }

    /// Read position into the recorder, advanced by each successful wait.
    private final class Cursor: @unchecked Sendable { var value = 0 }
    private let cursor = Cursor()

    func waitForStage(_ stage: JobStage, timeout: Duration = .seconds(30)) async -> JobSnapshot? {
        let event = await waitForEvent(timeout: timeout) { event in
            if case .jobUpdated(let snapshot) = event, snapshot.stage == stage { return true }
            return false
        }
        if case .jobUpdated(let snapshot)? = event { return snapshot }
        return nil
    }

    func waitForCompletion(timeout: Duration = .seconds(30)) async -> JobSnapshot? {
        await waitForStage(.completed, timeout: timeout)
    }

    func waitForFailure(timeout: Duration = .seconds(30)) async -> String? {
        let event = await waitForEvent(timeout: timeout) { event in
            if case .jobUpdated(let snapshot) = event, case .failed = snapshot.stage { return true }
            return false
        }
        if case .jobUpdated(let snapshot)? = event, case .failed(let message) = snapshot.stage { return message }
        return nil
    }

    /// Waits until `count` distinct jobs have completed.
    func waitForCompletions(count: Int, timeout: Duration = .seconds(60)) async -> Int {
        var done = Set<JobID>()
        let deadline = ContinuousClock.now + timeout
        while done.count < count {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero, let snapshot = await waitForCompletion(timeout: remaining) else { break }
            done.insert(snapshot.id)
        }
        return done.count
    }

    func waitForReleaseChoice() async -> JobID? {
        let event = await waitForEvent { event in
            if case .releaseChoiceNeeded = event { return true }
            return false
        }
        if case .releaseChoiceNeeded(let jobID)? = event { return jobID }
        return nil
    }
}

// MARK: Tests

@Suite struct PipelineTests {
    @Test func singleMatchEndToEnd() async throws {
        let harness = try PipelineHarness(releases: mockReleases(count: 1))
        defer { harness.tearDown() }

        await harness.start()
        harness.drive.insert("mockdisk")

        let completed = await harness.waitForCompletion()
        #expect(completed != nil, "job reaches completed")
        #expect(completed?.tracks.allSatisfy { $0.status == .transferred } == true, "every track reached the destination")

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

        await harness.start()
        harness.drive.insert("mockdisk")

        guard let jobID = await harness.waitForReleaseChoice() else {
            Issue.record("picker was not requested for ambiguous matches")
            return
        }

        await harness.coordinator.chooseRelease(jobID: jobID, candidateID: "REL-2")
        #expect(await harness.waitForCompletion() != nil, "job completes after user choice")
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

        await harness.start()
        harness.drive.insert("mockdisk")

        // Make sure BOTH stages are parked at the gate before answering:
        // the picker request (identify) and the rip finishing (processing).
        guard let jobID = await harness.waitForReleaseChoice() else {
            Issue.record("picker was not requested")
            return
        }
        #expect(await harness.waitForStage(.awaitingMetadata) != nil, "rip finished and the job waits for metadata")

        await harness.coordinator.chooseRelease(jobID: jobID, candidateID: "REL-2")

        let artEvent = await harness.waitForEvent(timeout: .seconds(10)) { event in
            if case .artLoaded(let id, _) = event { return id == jobID }
            return false
        }
        #expect(artEvent != nil, "cover art is fetched for the chosen release")
        #expect(await harness.waitForCompletion() != nil, "and the job still completes")
    }

    /// Regression (the other order): when the lookup is slower than the
    /// rip, the processing stage reaches the gate first; the picker answer
    /// must still wake it instead of leaving the job in awaitingMetadata.
    @Test func slowLookupDoesNotStrandTheJob() async throws {
        let harness = try PipelineHarness(
            releases: mockReleases(count: 3), autoPick: false, lookupDelay: .milliseconds(800)
        )
        defer { harness.tearDown() }

        await harness.start()
        harness.drive.insert("mockdisk")

        guard let jobID = await harness.waitForReleaseChoice() else {
            Issue.record("picker was not requested")
            return
        }
        await harness.coordinator.chooseRelease(jobID: jobID, candidateID: "REL-1")
        #expect(await harness.waitForCompletion(timeout: .seconds(15)) != nil, "job completes after the late choice")
    }

    /// A lone *fuzzy* (TOC search) hit is only a guess: with auto-pick off it
    /// must go through the picker like any other candidate list.
    @Test func singleFuzzyMatchRespectsAutoPickSetting() async throws {
        let harness = try PipelineHarness(releases: mockReleases(count: 1), autoPick: false, fuzzy: true)
        defer { harness.tearDown() }

        await harness.start()
        harness.drive.insert("mockdisk")

        #expect(await harness.waitForReleaseChoice() != nil, "fuzzy single match asks the user when auto-pick is off")
    }

    @Test func decliningThePickerTagsFromTheDisc() async throws {
        let harness = try PipelineHarness(releases: mockReleases(count: 3), autoPick: false)
        defer { harness.tearDown() }

        await harness.start()
        harness.drive.insert("mockdisk")

        guard let jobID = await harness.waitForReleaseChoice() else {
            Issue.record("picker was not requested")
            return
        }
        await harness.coordinator.declineReleaseChoice(jobID: jobID)
        let completed = await harness.waitForCompletion()
        #expect(completed?.album?.albumArtist == ResolvedAlbum.unknownArtist)
        let contents = (try? FileManager.default.subpathsOfDirectory(atPath: harness.library.path)) ?? []
        #expect(contents.contains { $0.hasSuffix(".flac") && $0.contains("Unknown Album") })
    }

    @Test func newDiscDuringUploadIsPickedUp() async throws {
        let harness = try PipelineHarness(releases: mockReleases(count: 1))
        defer { harness.tearDown() }

        await harness.start()
        harness.drive.insert("mockdisk")

        // Wait until the first disc is uploading: with eject-after-rip it has
        // already left the drive, yet its job is still non-terminal. That is
        // the exact window where a freshly inserted disc on the same bsdName
        // used to be silently dropped by the dedup guard.
        #expect(await harness.waitForStage(.transferring) != nil, "first disc reaches the transfer stage")

        // Insert a new disc into the same drive (same bsdName) mid-upload.
        harness.drive.insert("mockdisk")

        let completed = await harness.waitForCompletions(count: 2)
        #expect(completed == 2, "both discs were processed; the second was not dropped")
        #expect(harness.drive.ejectedDiscs.count == 2, "both discs ejected")
    }

    @Test func noMatchesFallsBackToUnknown() async throws {
        let harness = try PipelineHarness(releases: [])
        defer { harness.tearDown() }

        await harness.start()
        harness.drive.insert("mockdisk")

        #expect(await harness.waitForCompletion() != nil, "job completes without metadata")
        let contents = (try? FileManager.default.subpathsOfDirectory(atPath: harness.library.path)) ?? []
        #expect(
            contents.contains { $0.hasSuffix(".flac") && $0.contains("Unknown Album") },
            "files land under Unknown Album fallback"
        )
    }

    @Test func unknownDiscPausesForManualTags() async throws {
        let harness = try PipelineHarness(releases: [], unmatchedDiscPolicy: .askForTags)
        defer { harness.tearDown() }

        await harness.start()
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

        #expect(await harness.waitForCompletion() != nil, "job completes after manual tags")
        #expect(
            FileManager.default.fileExists(
                atPath: harness.library
                    .appendingPathComponent("Hand Artist/Hand Album (1999)/01 - Edited Opening.flac").path
            ),
            "hand-edited tags drive the file names"
        )
    }

    /// Regression: the transferred status used to be inferred from a "%02d"
    /// file-name prefix, which multi-disc names ("2-01 - …") don't have.
    @Test func multiDiscTracksReachTransferred() async throws {
        let harness = try PipelineHarness(releases: mockReleases(count: 1, discs: 2))
        defer { harness.tearDown() }

        await harness.start()
        harness.drive.insert("mockdisk")

        let completed = await harness.waitForCompletion()
        #expect(completed?.album?.discNumber == 2 && completed?.album?.discTotal == 2, "our disc is medium 2 of 2")
        #expect(completed?.tracks.map(\.status) == [.transferred, .transferred])
        #expect(
            FileManager.default.fileExists(
                atPath: harness.library.appendingPathComponent("Pipeline Artist/Pipeline Album 1 (2001)/2-01 - Opening.flac").path
            )
        )
    }

    @Test func unreadableDeviceFailsTheJobAndFreesTheDrive() async throws {
        let harness = try PipelineHarness(releases: mockReleases(count: 1), deviceFails: true)
        defer { harness.tearDown() }

        await harness.start()
        harness.drive.insert("mockdisk")

        let message = await harness.waitForFailure()
        #expect(message?.contains("DeviceUnavailable") == true)
        let history = await harness.coordinator.history()
        #expect(history.first?.succeeded == false)
        #expect(harness.drive.ejectedDiscs.isEmpty, "nothing to eject")
    }

    @Test func missingDestinationFailsAfterEncoding() async throws {
        let harness = try PipelineHarness(releases: mockReleases(count: 1), destination: false)
        defer { harness.tearDown() }

        await harness.start()
        harness.drive.insert("mockdisk")

        #expect(await harness.waitForStage(.encoding) != nil, "the rip and encode still happen")
        let message = await harness.waitForFailure()
        #expect(message?.contains("No destination") == true)
    }

    /// Preferences are frozen per job: flipping the eject timing while a
    /// disc is in flight must not leave it stuck in the drive.
    @Test func ejectTimingIsSnapshottedPerJob() async throws {
        let harness = try PipelineHarness(releases: mockReleases(count: 1), ejectTiming: .afterEverything)
        defer { harness.tearDown() }

        await harness.start()
        harness.drive.insert("mockdisk")

        #expect(await harness.waitForStage(.ripping) != nil)
        var flipped = Preferences()
        flipped.destination = .localFolder(path: harness.library.path)
        flipped.ripMode = .fast
        flipped.ejectTiming = .afterRip
        await harness.coordinator.updatePreferences(flipped)

        #expect(await harness.waitForCompletion() != nil)
        #expect(harness.drive.ejectedDiscs == ["mockdisk"], "ejected exactly once, at the end, as the job's own timing said")
    }
}
