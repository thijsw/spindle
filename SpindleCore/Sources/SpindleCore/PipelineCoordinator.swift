import DiscDrive
import Encoding
import Foundation
import Metadata
import Naming
import RipEngine
import Transfer
import Verification

/// Orchestrates the life of every inserted disc:
///
///   detect → hold/unmount → TOC → [rip ∥ identify] → eject → verify
///   → (await release choice if ambiguous) → encode → transfer → done
///
/// The drive is exclusive: discs rip one at a time. Everything after the rip
/// runs detached with bounded concurrency, so the next disc can start
/// ripping while the previous one encodes and uploads.
public actor PipelineCoordinator {
    public struct Dependencies: Sendable {
        public var drive: any DriveControlling
        public var deviceFactory: @Sendable (String) throws -> any CDDeviceIO
        public var driveIdentity: @Sendable (String) -> DriveIdentity?
        public var metadata: any MetadataProviding
        public var art: any ArtProviding
        public var verifier: (any RipVerifier)?
        public var destinationFactory: @Sendable (DestinationConfig) -> any Destination
        public var stagingRoot: URL

        public init(
            drive: any DriveControlling,
            deviceFactory: @escaping @Sendable (String) throws -> any CDDeviceIO,
            driveIdentity: @escaping @Sendable (String) -> DriveIdentity? = { _ in nil },
            metadata: any MetadataProviding,
            art: any ArtProviding,
            verifier: (any RipVerifier)?,
            destinationFactory: @escaping @Sendable (DestinationConfig) -> any Destination,
            stagingRoot: URL
        ) {
            self.drive = drive
            self.deviceFactory = deviceFactory
            self.driveIdentity = driveIdentity
            self.metadata = metadata
            self.art = art
            self.verifier = verifier
            self.destinationFactory = destinationFactory
            self.stagingRoot = stagingRoot
        }

        /// Production wiring.
        public static func live(userAgent: String) throws -> Dependencies {
            Dependencies(
                drive: try SystemDriveController(),
                deviceFactory: { try CDDrive(bsdName: $0) },
                driveIdentity: { DiscEnumerator.driveIdentity(forMediaBSDName: $0) },
                metadata: MusicBrainzClient(userAgent: userAgent),
                art: CoverArtClient(userAgent: userAgent),
                verifier: CTDBVerifier(userAgent: userAgent),
                destinationFactory: { config in
                    switch config {
                    case .localFolder(let path): LocalFolderDestination(path: path)
                    case .sftp(let sftpConfig): SFTPDestination(config: sftpConfig)
                    }
                },
                stagingRoot: PreferencesStore.applicationSupportURL.appendingPathComponent("Staging")
            )
        }
    }

    // MARK: State

    private final class Job {
        let id = JobID()
        let bsdName: String
        var snapshot: JobSnapshot
        var toc: TOC?
        var discTOC: DiscTOC?
        var cdText: CDTextInfo?
        var rankedReleases: [ReleaseScorer.Ranked] = []
        var rippedTracks: [RippedTrack] = []
        var ctdbDiscCRC: UInt32?
        var art: CoverArt?
        var resolution: CheckedContinuation<ResolvedAlbum, Never>?
        var resolvedAlbum: ResolvedAlbum?
        var stagingDir: URL

        init(bsdName: String, stagingRoot: URL) {
            self.bsdName = bsdName
            self.stagingDir = stagingRoot.appendingPathComponent(UUID().uuidString)
            self.snapshot = JobSnapshot(
                id: id,
                bsdName: bsdName,
                stage: .detected,
                discID: nil,
                album: nil,
                artData: nil,
                tracks: [],
                candidates: [],
                verificationSummary: nil,
                startedAt: Date(),
                finishedAt: nil
            )
        }
    }

    private var preferences: Preferences
    private let dependencies: Dependencies
    private let jobStore: JobStore
    private var jobs: [JobID: Job] = [:]
    private var ripLaneBusy = false
    private var pendingDiscs: [String] = []
    private var eventContinuation: AsyncStream<PipelineEvent>.Continuation?
    private let encodeSlots = AsyncSemaphore(value: 2)
    private let transferSlots = AsyncSemaphore(value: 1)
    private var started = false

    public nonisolated let events: AsyncStream<PipelineEvent>

    public init(preferences: Preferences, dependencies: Dependencies, jobStore: JobStore) {
        self.preferences = preferences
        self.dependencies = dependencies
        self.jobStore = jobStore
        var continuation: AsyncStream<PipelineEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.eventContinuation = continuation
    }

    public func updatePreferences(_ preferences: Preferences) {
        self.preferences = preferences
    }

    /// Begins watching the drive. Discs already in the drive are processed.
    public func start() {
        guard !started else { return }
        started = true

        for bsd in dependencies.drive.presentDiscs() {
            enqueueDisc(bsdName: bsd)
        }

        let stream = dependencies.drive.driveEvents
        Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                switch event {
                case .discAppeared(let bsd):
                    await self.enqueueDisc(bsdName: bsd)
                case .discDisappeared:
                    break // surprise removals surface as rip errors
                }
            }
        }
    }

    /// UI answer to `releaseChoiceNeeded`.
    public func chooseRelease(jobID: JobID, candidateID: String) {
        guard let job = jobs[jobID],
              let ranked = job.rankedReleases.first(where: { $0.release.id == candidateID }),
              let toc = job.toc
        else { return }
        let album = ResolvedAlbum(
            release: ranked.release,
            discID: job.discTOC?.musicBrainzDiscID,
            audioTrackCount: toc.audioTracks.count
        ) ?? ResolvedAlbum.fallback(
            cdText: job.cdText,
            discID: job.discTOC?.musicBrainzDiscID,
            trackCount: toc.audioTracks.count
        )
        resolve(job: job, album: album)
    }

    /// Fallback when the user dismisses the picker: tag from CD-TEXT/unknown.
    public func declineReleaseChoice(jobID: JobID) {
        guard let job = jobs[jobID], let toc = job.toc else { return }
        resolve(job: job, album: ResolvedAlbum.fallback(
            cdText: job.cdText,
            discID: job.discTOC?.musicBrainzDiscID,
            trackCount: toc.audioTracks.count
        ))
    }

    public func currentSnapshots() -> [JobSnapshot] {
        jobs.values.map(\.snapshot).sorted { $0.startedAt < $1.startedAt }
    }

    public func history() async -> [JobRecord] {
        await jobStore.history()
    }

    // MARK: Disc intake

    private func enqueueDisc(bsdName: String) {
        guard !jobs.values.contains(where: { $0.bsdName == bsdName && !$0.snapshot.stage.isTerminal }) else {
            return
        }
        pendingDiscs.append(bsdName)
        pumpRipLane()
    }

    private func pumpRipLane() {
        guard !ripLaneBusy, !pendingDiscs.isEmpty else { return }
        ripLaneBusy = true
        let bsd = pendingDiscs.removeFirst()
        let job = Job(bsdName: bsd, stagingRoot: dependencies.stagingRoot)
        jobs[job.id] = job
        publish(job)

        Task {
            await self.runDriveStages(jobID: job.id)
            await self.finishRipLane()
        }
    }

    private func finishRipLane() {
        ripLaneBusy = false
        pumpRipLane()
    }

    // MARK: Stage helpers

    private func publish(_ job: Job) {
        eventContinuation?.yield(.jobUpdated(job.snapshot))
    }

    private func setStage(_ job: Job, _ stage: JobStage) {
        job.snapshot.stage = stage
        if stage.isTerminal {
            job.snapshot.finishedAt = Date()
        }
        publish(job)
    }

    private func failJob(_ job: Job, _ message: String) async {
        setStage(job, .failed(message))
        await jobStore.append(JobRecord(snapshot: job.snapshot))
        eventContinuation?.yield(.notify(
            title: "Disc failed",
            body: "\(job.snapshot.displayTitle): \(message)"
        ))
        try? FileManager.default.removeItem(at: job.stagingDir)
        dependencies.drive.release(bsdName: job.bsdName)
    }

    private func resolve(job: Job, album: ResolvedAlbum) {
        guard job.resolvedAlbum == nil else { return }
        job.resolvedAlbum = album
        job.snapshot.album = album
        job.snapshot.candidates = []
        // Update track titles in place.
        for index in job.snapshot.tracks.indices {
            let number = job.snapshot.tracks[index].number
            if let track = album.tracks.first(where: { $0.position == number }) {
                job.snapshot.tracks[index].title = track.title
            }
        }
        publish(job)
        job.resolution?.resume(returning: album)
        job.resolution = nil
    }

    private func updateTrack(_ job: Job, number: Int, status: TrackState.Status) {
        guard let index = job.snapshot.tracks.firstIndex(where: { $0.number == number }) else { return }
        job.snapshot.tracks[index].status = status
        publish(job)
    }

    // MARK: Drive-bound stages (exclusive)

    private func runDriveStages(jobID: JobID) async {
        guard let job = jobs[jobID] else { return }

        do {
            setStage(job, .readingTOC)
            try? await dependencies.drive.hold(bsdName: job.bsdName)
            let device = try dependencies.deviceFactory(job.bsdName)

            let toc = try await TOC.parse(fullTOC: device.readFullTOC())
            guard let discTOC = DiscTOC(toc: toc) else {
                await failJob(job, "No audio tracks on this disc")
                return
            }
            job.toc = toc
            job.discTOC = discTOC
            job.snapshot.discID = discTOC.musicBrainzDiscID
            if let packs = ((try? await device.readCDTextPacks()) ?? nil) {
                job.cdText = CDTextParser.parse(packs: packs)
            }
            job.snapshot.tracks = toc.audioTracks.map { track in
                TrackState(
                    number: track.number,
                    title: job.cdText?.trackTitles[track.number] ?? String(format: "Track %02d", track.number),
                    durationSeconds: Double(toc.lengthInSectors(of: track)) / 75.0
                )
            }
            publish(job)

            // Metadata lookup runs concurrently with the rip.
            Task { await self.identify(jobID: jobID) }

            setStage(job, .ripping)
            let identity = dependencies.driveIdentity(job.bsdName)
            let config = preferences.ripConfiguration(
                forDrive: identity?.offsetKey
            )
            let ripper = DiscRipper(device: device, config: config)
            let result = try await ripper.ripDisc(toc: toc, to: job.stagingDir) { [weak self] progress in
                guard let self else { return }
                Task { await self.ripProgress(jobID: jobID, progress: progress) }
            }
            job.rippedTracks = result.tracks
            job.ctdbDiscCRC = result.ctdbDiscCRC32
            for track in result.tracks {
                updateTrack(job, number: track.trackNumber, status: .ripped)
            }
            setStage(job, .ripped)

            if preferences.ejectTiming == .afterRip {
                try? await dependencies.drive.eject(bsdName: job.bsdName)
                eventContinuation?.yield(.notify(
                    title: "Disc ripped",
                    body: "\(job.snapshot.displayTitle) — you can insert the next disc."
                ))
            }

            // Everything else happens off the rip lane.
            Task { await self.runProcessingStages(jobID: jobID) }
        } catch {
            await failJob(job, String(describing: error))
        }
    }

    private var lastProgressUpdate = ContinuousClock.now

    private func ripProgress(jobID: JobID, progress: RipProgress) {
        guard let job = jobs[jobID] else { return }
        // Throttle UI updates to ~10 Hz.
        let now = ContinuousClock.now
        guard now - lastProgressUpdate > .milliseconds(100) || progress.fraction == 1 else { return }
        lastProgressUpdate = now
        updateTrack(
            job,
            number: progress.trackNumber,
            status: progress.fraction >= 1 ? .ripped : .ripping(progress.fraction)
        )
    }

    // MARK: Identification (concurrent with rip)

    private func identify(jobID: JobID) async {
        guard let job = jobs[jobID], let discTOC = job.discTOC, let toc = job.toc else { return }

        var ranked: [ReleaseScorer.Ranked] = []
        do {
            let result = try await dependencies.metadata.lookup(disc: discTOC)
            let releases: [MBRelease]
            switch result {
            case .matched(let r), .fuzzy(let r): releases = r
            case .none: releases = []
            }
            ranked = ReleaseScorer(preferences: preferences.metadata).rank(
                releases,
                discID: discTOC.musicBrainzDiscID,
                audioTrackCount: toc.audioTracks.count
            )
        } catch {
            // Network trouble: fall back to CD-TEXT silently.
        }
        guard let job = jobs[jobID] else { return }
        job.rankedReleases = ranked

        if let best = ranked.first,
           ranked.count == 1 || (preferences.autoPickRelease && best.confidence >= preferences.metadata.autoPickThreshold),
           let album = ResolvedAlbum(
               release: best.release,
               discID: discTOC.musicBrainzDiscID,
               audioTrackCount: toc.audioTracks.count
           ) {
            resolve(job: job, album: album)
        } else if ranked.isEmpty {
            resolve(job: job, album: ResolvedAlbum.fallback(
                cdText: job.cdText,
                discID: discTOC.musicBrainzDiscID,
                trackCount: toc.audioTracks.count
            ))
        } else {
            job.snapshot.candidates = ranked.map(ReleaseCandidate.init(ranked:))
            publish(job)
            eventContinuation?.yield(.releaseChoiceNeeded(job.id))
        }

        // Fetch art as soon as we know the album (await the resolution).
        if let album = await awaitResolution(jobID: jobID) {
            let art = await dependencies.art.fetchArt(
                releaseMBID: album.releaseMBID,
                releaseGroupMBID: album.releaseGroupMBID,
                fallbackQuery: "\(album.albumArtist) \(album.album)",
                size: preferences.coverArtSize
            )
            if let job = jobs[jobID], let art {
                job.art = art
                job.snapshot.artData = art.data
                publish(job)
            }
        }
    }

    private func awaitResolution(jobID: JobID) async -> ResolvedAlbum? {
        guard let job = jobs[jobID] else { return nil }
        if let resolved = job.resolvedAlbum { return resolved }
        return await withCheckedContinuation { continuation in
            job.resolution = continuation
        }
    }

    // MARK: Post-rip stages (detached from the rip lane)

    private func runProcessingStages(jobID: JobID) async {
        guard let job = jobs[jobID], let toc = job.toc else { return }

        // Verification (non-fatal).
        if let verifier = dependencies.verifier {
            let checksums = job.rippedTracks.reduce(into: [Int: TrackChecksums]()) {
                $0[$1.trackNumber] = $1.checksums
            }
            if let result = try? await verifier.verify(
                toc: toc, trackChecksums: checksums, ctdbDiscCRC32: job.ctdbDiscCRC
            ) {
                job.snapshot.verificationSummary = result.summary
                for (number, verdict) in result.trackVerdicts {
                    if case .accuratelyRipped = verdict {
                        updateTrack(job, number: number, status: .verified(true))
                    } else if case .differs = verdict {
                        updateTrack(job, number: number, status: .verified(false))
                    }
                }
                publish(job)
            }
        }

        // Wait for metadata if the picker is still open.
        if job.resolvedAlbum == nil {
            setStage(job, .awaitingMetadata)
        }
        guard let album = await awaitResolution(jobID: jobID) else { return }

        await encodeAndTransfer(jobID: jobID, album: album)
    }

    private func encodeAndTransfer(jobID: JobID, album: ResolvedAlbum) async {
        guard let job = jobs[jobID] else { return }

        do {
            // Encode.
            setStage(job, .encoding)
            await encodeSlots.wait()
            defer { Task { await self.encodeSlots.signal() } }

            let encodedDir = job.stagingDir.appendingPathComponent("encoded")
            var uploads: [(URL, String)] = []
            var albumFolders: Set<String> = []

            for ripped in job.rippedTracks {
                let position = trackPosition(of: ripped, in: job)
                guard let track = album.tracks.first(where: { $0.position == position }) else {
                    continue
                }
                let tags = TrackTags(album: album, track: track)
                for format in preferences.formats {
                    let relative = preferences.namingTemplate.render(album: album, track: track)
                        + "." + format.fileExtension
                    let target = encodedDir.appendingPathComponent(relative)
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    let encoder: any TrackEncoder = format == .flac ? FLACEncoder() : ALACEncoder()
                    try await encoder.encode(wav: ripped.wavURL, to: target, tags: tags, art: job.art)
                    uploads.append((target, relative))
                    albumFolders.insert((relative as NSString).deletingLastPathComponent)
                }
                updateTrack(job, number: ripped.trackNumber, status: .encoded)
            }

            if preferences.writeCoverJPEG, let art = job.art {
                for folder in albumFolders {
                    let coverRelative = folder.isEmpty
                        ? "cover.\(art.fileExtension)"
                        : "\(folder)/cover.\(art.fileExtension)"
                    let coverURL = encodedDir.appendingPathComponent(coverRelative)
                    try? art.data.write(to: coverURL)
                    uploads.append((coverURL, coverRelative))
                }
            }

            // Transfer.
            guard let destinationConfig = preferences.destination else {
                await failJob(job, "No destination configured — set one in Settings")
                return
            }
            setStage(job, .transferring)
            await transferSlots.wait()
            defer { Task { await self.transferSlots.signal() } }

            let destination = dependencies.destinationFactory(destinationConfig)
            try await destination.prepare()
            for (url, relative) in uploads {
                try await destination.upload(file: url, toRelativePath: relative, progress: nil)
                if let number = trackNumber(fromRelativePath: relative, album: album) {
                    updateTrack(job, number: number, status: .transferred)
                }
            }
            await destination.close()

            // Done.
            if preferences.ejectTiming == .afterEverything {
                try? await dependencies.drive.eject(bsdName: job.bsdName)
            }
            dependencies.drive.release(bsdName: job.bsdName)
            setStage(job, .completed)
            await jobStore.append(JobRecord(snapshot: job.snapshot))
            eventContinuation?.yield(.notify(
                title: "Album ready",
                body: "\(job.snapshot.displayTitle) → \(destinationConfig.displayName)"
            ))
            try? FileManager.default.removeItem(at: job.stagingDir)
        } catch {
            await failJob(job, String(describing: error))
        }
    }

    /// Maps a ripped track (by disc track number) to its album position:
    /// identical for single-session discs ripped in order.
    private func trackPosition(of ripped: RippedTrack, in job: Job) -> Int {
        ripped.trackNumber
    }

    private func trackNumber(fromRelativePath relative: String, album: ResolvedAlbum) -> Int? {
        guard let file = relative.split(separator: "/").last else { return nil }
        for track in album.tracks {
            if file.hasPrefix(String(format: "%02d", track.position)) {
                return track.position
            }
        }
        return nil
    }
}
