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
        /// Preferences frozen at intake. A settings change mid-job must not
        /// leave a disc half-configured (e.g. neither eject branch firing
        /// because the timing flipped between rip and transfer). The
        /// destination is the one exception, read at delivery time so a
        /// destination configured mid-batch still applies.
        let preferences: Preferences
        /// Set once the physical disc has left the drive. After this point a
        /// disc reappearing on the same `bsdName` is a *different* disc, so it
        /// must not be deduplicated against this (still-processing) job.
        var ejected = false
        var snapshot: JobSnapshot
        var toc: TOC?
        var discTOC: DiscTOC?
        var cdText: CDTextInfo?
        var rankedReleases: [ReleaseScorer.Ranked] = []
        // Rip provenance, kept for the archival log written at encode time.
        var ripOutcome: VerifiedRipper.Outcome?
        var ripConfig: RipConfiguration?
        var driveIdentity: DriveIdentity?
        var ripDuration: Duration?
        var art: CoverArt?
        let metadata = MetadataGate()
        var transferRate = TransferRateEstimator()
        let stagingDir: URL

        init(bsdName: String, preferences: Preferences, stagingRoot: URL) {
            self.bsdName = bsdName
            self.preferences = preferences
            self.stagingDir = stagingRoot.appendingPathComponent(UUID().uuidString)
            self.snapshot = JobSnapshot(
                id: id,
                bsdName: bsdName,
                stage: .detected,
                discID: nil,
                album: nil,
                hasArt: false,
                tracks: [],
                candidates: [],
                verificationSummary: nil,
                startedAt: Date(),
                finishedAt: nil
            )
        }
    }

    /// One file headed for the destination.
    private struct Upload {
        let url: URL
        let relativePath: String
        /// Disc track number for audio files; nil for cover/log/cue.
        let trackNumber: Int?
    }

    private var preferences: Preferences
    private let dependencies: Dependencies
    private let jobStore: JobStore
    private var jobs: [JobID: Job] = [:]
    private var ripLaneBusy = false
    private var pendingDiscs: [String] = []
    private let eventContinuation: AsyncStream<PipelineEvent>.Continuation
    private let encodeSlots = AsyncSemaphore(value: 2)
    private let transferSlots = AsyncSemaphore(value: 1)
    private var started = false
    private var lastProgressUpdate = ContinuousClock.now

    public nonisolated let events: AsyncStream<PipelineEvent>

    public init(preferences: Preferences, dependencies: Dependencies, jobStore: JobStore) {
        self.preferences = preferences
        self.dependencies = dependencies
        self.jobStore = jobStore
        (self.events, self.eventContinuation) = AsyncStream.makeStream(
            of: PipelineEvent.self, bufferingPolicy: .unbounded
        )
    }

    /// Applies to discs inserted from now on; running jobs keep the
    /// preferences they started with.
    public func updatePreferences(_ preferences: Preferences) {
        self.preferences = preferences
    }

    /// Begins watching the drive. Discs already in the drive are processed.
    public func start() {
        guard !started else { return }
        started = true

        rescanPresentDiscs()

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

    // MARK: Metadata answers from the UI

    /// UI answer to `releaseChoiceNeeded`.
    public func chooseRelease(jobID: JobID, candidateID: String) {
        guard let job = jobs[jobID],
              let album = tagEditorDraft(jobID: jobID, candidateID: candidateID)
        else { return }
        resolve(job: job, album: album)
    }

    /// Fallback when the user dismisses the picker: tag from CD-TEXT/unknown.
    public func declineReleaseChoice(jobID: JobID) {
        guard let job = jobs[jobID], let album = fallbackAlbum(for: job) else { return }
        resolve(job: job, album: album)
    }

    /// Pre-filled draft for the manual tag editor: the given candidate when
    /// one is chosen, otherwise CD-TEXT/fallback tags.
    public func tagEditorDraft(jobID: JobID, candidateID: String?) -> ResolvedAlbum? {
        guard let job = jobs[jobID] else { return nil }
        if let candidateID,
           let ranked = job.rankedReleases.first(where: { $0.release.id == candidateID }),
           let album = resolvedAlbum(for: job, release: ranked.release) {
            return album
        }
        return fallbackAlbum(for: job)
    }

    /// Hand-edited tags from the tag editor; resolves the job like a picker
    /// choice would.
    public func provideTags(jobID: JobID, album: ResolvedAlbum) {
        guard let job = jobs[jobID] else { return }
        resolve(job: job, album: album)
    }

    public func history() async -> [JobRecord] {
        await jobStore.history()
    }

    // MARK: Disc intake

    private func enqueueDisc(bsdName: String) {
        // Dedup only against a job that still owns the physical drive slot: one
        // that hasn't finished AND hasn't ejected its disc. A job that ejected
        // (eject-after-rip, still encoding/uploading) no longer holds the
        // drive, so a disc on the same bsdName is genuinely a new disc.
        guard !jobs.values.contains(where: {
            $0.bsdName == bsdName && !$0.snapshot.stage.isTerminal && !$0.ejected
        }) else {
            return
        }
        // Also guard against re-queuing a disc already waiting in line.
        guard !pendingDiscs.contains(bsdName) else { return }
        pendingDiscs.append(bsdName)
        pumpRipLane()
    }

    private func pumpRipLane() {
        guard !ripLaneBusy, !pendingDiscs.isEmpty else { return }
        ripLaneBusy = true
        let bsd = pendingDiscs.removeFirst()
        let job = Job(bsdName: bsd, preferences: preferences, stagingRoot: dependencies.stagingRoot)
        jobs[job.id] = job
        publish(job)

        Task {
            await self.runDriveStages(jobID: job.id)
            self.finishRipLane()
        }
    }

    private func finishRipLane() {
        ripLaneBusy = false
        // Safety net: a disc already sitting in the drive (e.g. its appearance
        // event landed while we were busy) gets picked up now that the lane is
        // free. enqueueDisc dedups, so this never double-processes a disc an
        // active job still owns.
        rescanPresentDiscs()
        pumpRipLane()
    }

    /// Enqueue any disc physically present in a drive that no active job owns.
    /// Backs up the DiskArbitration appearance stream against dropped events.
    private func rescanPresentDiscs() {
        for bsd in dependencies.drive.presentDiscs() {
            enqueueDisc(bsdName: bsd)
        }
    }

    // MARK: Stage helpers

    private func publish(_ job: Job) {
        eventContinuation.yield(.jobUpdated(job.snapshot))
    }

    private func notify(title: String, body: String) {
        eventContinuation.yield(.notify(title: title, body: body))
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
        // Wake anything still waiting for an album choice (the art fetch,
        // the processing stage); the job is over.
        job.metadata.cancel()
        await jobStore.append(JobRecord(snapshot: job.snapshot))
        notify(title: "Disc failed", body: "\(job.snapshot.displayTitle): \(message)")
        Self.removeStaging(job.stagingDir)
        // Only release if we still hold the drive. If the disc already ejected
        // (afterRip failure during encode/upload), a new disc may now hold this
        // bsdName — releasing would drop its mount protection.
        if !job.ejected {
            dependencies.drive.release(bsdName: job.bsdName)
        }
    }

    /// Deleting hundreds of megabytes of staged WAVs must not block the
    /// actor that also answers the UI.
    private static func removeStaging(_ directory: URL) {
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func resolvedAlbum(for job: Job, release: MBRelease) -> ResolvedAlbum? {
        guard let toc = job.toc else { return nil }
        return ResolvedAlbum(
            release: release,
            discID: job.discTOC?.musicBrainzDiscID,
            audioTrackCount: toc.audioTracks.count
        )
    }

    /// CD-TEXT/unknown tagging for discs MusicBrainz can't (or wasn't allowed
    /// to) resolve. Nil only before the TOC has been read.
    private func fallbackAlbum(for job: Job) -> ResolvedAlbum? {
        guard let toc = job.toc else { return nil }
        return .fallback(
            cdText: job.cdText,
            discID: job.discTOC?.musicBrainzDiscID,
            trackCount: toc.audioTracks.count
        )
    }

    private func resolve(job: Job, album: ResolvedAlbum) {
        guard !job.metadata.isSettled else { return }
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
        job.metadata.resolve(album)
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
            let config = job.preferences.ripConfiguration(forDrive: identity?.offsetKey)
            // Verify-first: burst rip, confirm against CTDB, securely re-rip
            // only what the database can't vouch for.
            let ripper = VerifiedRipper(
                device: device,
                configuration: config,
                verifier: dependencies.verifier
            )
            let ripStarted = ContinuousClock.now
            let outcome = try await ripper.rip(toc: toc, to: job.stagingDir) { [weak self] progress in
                guard let self else { return }
                Task { await self.ripProgress(jobID: jobID, progress: progress) }
            }
            job.ripOutcome = outcome
            job.ripConfig = config
            job.driveIdentity = identity
            job.ripDuration = ContinuousClock.now - ripStarted
            applyRipOutcome(outcome, to: job, driveKey: identity?.offsetKey)
            setStage(job, .ripped)

            // Close the raw device before ejecting — an open /dev/rdiskN
            // keeps the disc busy and DADiskEject fails silently.
            await device.close()

            if job.preferences.ejectTiming == .afterRip {
                try? await dependencies.drive.eject(bsdName: job.bsdName)
                job.ejected = true // a disc now inserted here is a new disc
                notify(
                    title: "Disc ripped",
                    body: "\(job.snapshot.displayTitle) — you can insert the next disc."
                )
            }

            // Everything else happens off the rip lane.
            Task { await self.runProcessingStages(jobID: jobID) }
        } catch {
            await failJob(job, String(describing: error))
        }
    }

    /// Reflects the rip's verdicts in the job's track states and surfaces
    /// the drive-level findings (unreliable C2, abandoned tracks).
    private func applyRipOutcome(_ outcome: VerifiedRipper.Outcome, to job: Job, driveKey: String?) {
        job.snapshot.verificationSummary = outcome.verification?.summary
            ?? outcome.verificationError.map { "Verification unavailable: \($0)" }
            ?? outcome.summary
        if outcome.c2Unreliable, let driveKey {
            eventContinuation.yield(.c2Unreliable(driveKey: driveKey))
        }
        for number in outcome.failedTracks {
            updateTrack(job, number: number, status: .failed("Unreadable — gave up after the time limit"))
        }
        if !outcome.failedTracks.isEmpty {
            notify(
                title: "Some tracks could not be read",
                body: "\(job.snapshot.displayTitle): track(s) \(outcome.failedTracks.map(String.init).joined(separator: ", ")) were skipped."
            )
        }
        for track in outcome.tracks {
            updateTrack(job, number: track.trackNumber, status: .ripped)
        }
        if let verification = outcome.verification {
            for (number, verdict) in verification.trackVerdicts {
                if case .accuratelyRipped = verdict {
                    updateTrack(job, number: number, status: .verified(true))
                } else if case .differs = verdict {
                    updateTrack(job, number: number, status: .verified(false))
                }
            }
        }
    }

    private func ripProgress(jobID: JobID, progress: RipProgress) {
        guard let job = jobs[jobID],
              let index = job.snapshot.tracks.firstIndex(where: { $0.number == progress.trackNumber })
        else { return }
        // Progress ticks arrive through independent tasks and may land after
        // the rip has already advanced the track — never regress a track
        // that is past ripping.
        switch job.snapshot.tracks[index].status {
        case .waiting, .ripping: break
        default: return
        }
        // Throttle the live percentage to ~4 Hz. This re-renders the main
        // window's track table (cheap), but must NOT churn the menu-bar
        // scene — see AppModel.menuBarSummary, which only changes on coarse
        // stage transitions, not on these ticks.
        let now = ContinuousClock.now
        guard now - lastProgressUpdate > .milliseconds(250) || progress.fraction >= 1 else { return }
        lastProgressUpdate = now
        job.snapshot.tracks[index].status = progress.fraction >= 1 ? .ripped : .ripping(progress.fraction)
        publish(job)
    }

    // MARK: Identification (concurrent with rip)

    /// What to do with the ranked MusicBrainz candidates for a disc.
    enum ResolutionDecision {
        /// Tag from this release without asking.
        case autoPick(ReleaseScorer.Ranked)
        /// Several plausible releases: show the picker.
        case pick
        /// No candidates and the user wants to hand-edit tags.
        case askForTags
        /// No candidates: tag from CD-TEXT/unknown and continue.
        case fallback
    }

    /// Pure decision, separated for testability. A single release attached
    /// to the disc's own DiscID leaves nothing to choose; a single *fuzzy*
    /// (TOC-search) hit is only a guess and goes through the auto-pick
    /// settings like any other.
    static func decideResolution(
        ranked: [ReleaseScorer.Ranked],
        exactDiscID: Bool,
        preferences: Preferences
    ) -> ResolutionDecision {
        guard let best = ranked.first else {
            return preferences.unmatchedDiscPolicy == .askForTags ? .askForTags : .fallback
        }
        if ranked.count == 1, exactDiscID { return .autoPick(best) }
        if preferences.autoPickRelease, best.confidence >= preferences.metadata.autoPickThreshold {
            return .autoPick(best)
        }
        return .pick
    }

    private func identify(jobID: JobID) async {
        guard let job = jobs[jobID], let discTOC = job.discTOC, let toc = job.toc else { return }
        let preferences = job.preferences

        var ranked: [ReleaseScorer.Ranked] = []
        var exactDiscID = false
        do {
            let releases: [MBRelease]
            switch try await dependencies.metadata.lookup(disc: discTOC) {
            case .matched(let found):
                releases = found
                exactDiscID = true
            case .fuzzy(let found):
                releases = found
            case .none:
                releases = []
            }
            ranked = ReleaseScorer(preferences: preferences.metadata).rank(
                releases,
                discID: discTOC.musicBrainzDiscID,
                audioTrackCount: toc.audioTracks.count
            )
        } catch {
            // Network trouble: fall back to CD-TEXT silently.
        }
        guard let job = jobs[jobID], !job.metadata.isSettled else { return }
        job.rankedReleases = ranked

        switch Self.decideResolution(ranked: ranked, exactDiscID: exactDiscID, preferences: preferences) {
        case .autoPick(let best):
            let discID = discTOC.musicBrainzDiscID
            let cdText = job.cdText
            let album = ResolvedAlbum(release: best.release, discID: discID, audioTrackCount: toc.audioTracks.count)
                ?? .fallback(cdText: cdText, discID: discID, trackCount: toc.audioTracks.count)
            resolve(job: job, album: album)
        case .askForTags:
            // Pause for hand-edited tags (the rip itself keeps going); the
            // UI answers with provideTags or declineReleaseChoice.
            eventContinuation.yield(.tagsNeeded(job.id))
        case .fallback:
            if let album = fallbackAlbum(for: job) {
                resolve(job: job, album: album)
            }
        case .pick:
            job.snapshot.candidates = ranked.map(ReleaseCandidate.init(ranked:))
            publish(job)
            eventContinuation.yield(.releaseChoiceNeeded(job.id))
        }

        // Fetch art as soon as the album is known (however it gets chosen).
        guard let album = await job.metadata.wait() else { return }
        let art = await dependencies.art.fetchArt(
            releaseMBID: album.releaseMBID,
            releaseGroupMBID: album.releaseGroupMBID,
            // A name search for "Unknown Artist Unknown Album" returns
            // somebody else's cover; only search when the names are real.
            fallbackQuery: album.hasPlaceholderNames ? nil : "\(album.albumArtist) \(album.album)",
            size: preferences.coverArtSize
        )
        guard let job = jobs[jobID], let art, !job.snapshot.stage.isTerminal else { return }
        job.art = art
        job.snapshot.hasArt = true
        publish(job)
        // Bytes out of band: the snapshot stays small and cheap.
        eventContinuation.yield(.artLoaded(job.id, art.data))
    }

    // MARK: Post-rip stages (detached from the rip lane)

    private func runProcessingStages(jobID: JobID) async {
        guard let job = jobs[jobID] else { return }
        // Verification already happened inside the verify-first rip
        // (drive-bound, so failed tracks could be re-ripped before eject).

        // Wait for metadata if the picker is still open.
        if !job.metadata.isSettled {
            setStage(job, .awaitingMetadata)
        }
        guard let album = await job.metadata.wait() else { return }

        // Each slot is held for its own stage only — an upload must never sit
        // on one of the two encode slots — and released on every exit path.
        do {
            await encodeSlots.wait()
            setStage(job, .encoding)
            let uploads: [Upload]
            do {
                uploads = try await encode(job, album: album)
            } catch {
                encodeSlots.signal()
                throw error
            }
            encodeSlots.signal()

            // Read live (not from the job's snapshot) so a destination the
            // user configures while the first disc rips still applies.
            guard let destinationConfig = preferences.destination else {
                await failJob(job, "No destination configured — set one in Settings")
                return
            }
            await transferSlots.wait()
            setStage(job, .transferring)
            do {
                try await transfer(job, uploads: uploads, to: destinationConfig)
            } catch {
                transferSlots.signal()
                throw error
            }
            transferSlots.signal()
            await complete(job, deliveredTo: destinationConfig)
        } catch {
            await failJob(job, String(describing: error))
        }
    }

    /// Encodes every ripped track into the staging "encoded" folder and adds
    /// the per-folder extras (cover, rip log, cue sheet).
    private func encode(_ job: Job, album: ResolvedAlbum) async throws -> [Upload] {
        let preferences = job.preferences
        let encodedDir = job.stagingDir.appendingPathComponent("encoded")
        let format = preferences.format
        let encoder = format.makeEncoder()

        var uploads: [Upload] = []
        // Album folder (relative) → track position → file name; multi-disc
        // templates spread one album over several folders.
        var folders: [String: [Int: String]] = [:]

        for ripped in job.ripOutcome?.tracks ?? [] {
            // Ripped tracks map to album positions by disc track number
            // (single-session discs, ripped in order).
            guard let track = album.tracks.first(where: { $0.position == ripped.trackNumber }) else {
                continue
            }
            let relative = preferences.namingTemplate.render(album: album, track: track)
                + "." + format.fileExtension
            let target = encodedDir.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try await encoder.encode(
                wav: ripped.wavURL, to: target, tags: TrackTags(album: album, track: track), art: job.art
            )
            uploads.append(Upload(url: target, relativePath: relative, trackNumber: ripped.trackNumber))
            let path = relative as NSString
            folders[path.deletingLastPathComponent, default: [:]][track.position] = path.lastPathComponent
            updateTrack(job, number: ripped.trackNumber, status: .encoded)
        }

        // Archival artifacts, named "<Artist> - <Album>" like EAC's.
        let baseName = PathSanitizer.component("\(album.albumArtist) - \(album.album)")
        let ripLog: String? = if preferences.writeRipLog, let outcome = job.ripOutcome, let toc = job.toc {
            RipLog(
                drive: job.driveIdentity,
                configuration: job.ripConfig ?? RipConfiguration(),
                toc: toc,
                discTOC: job.discTOC,
                album: album,
                outcome: outcome,
                ripDuration: job.ripDuration
            ).render()
        } else {
            nil
        }

        for (folder, fileNames) in folders.sorted(by: { $0.key < $1.key }) {
            func emit(_ name: String, _ write: (URL) throws -> Void) throws {
                let relative = folder.isEmpty ? name : "\(folder)/\(name)"
                let url = encodedDir.appendingPathComponent(relative)
                try write(url)
                uploads.append(Upload(url: url, relativePath: relative, trackNumber: nil))
            }
            if preferences.writeCoverJPEG, let art = job.art {
                try emit("cover.\(art.fileExtension)") { try art.data.write(to: $0) }
            }
            if let ripLog {
                try emit("\(baseName).log") { try ripLog.write(to: $0, atomically: true, encoding: .utf8) }
            }
            if preferences.writeCueSheet, let toc = job.toc {
                let cue = CueSheet.render(
                    album: album,
                    toc: toc,
                    discTOC: job.discTOC,
                    fileNames: fileNames, // only the tracks whose files live in this folder
                    comment: "Spindle \(RipLog.currentAppVersion)"
                )
                try emit("\(baseName).cue") { try cue.write(to: $0, atomically: true, encoding: .utf8) }
            }
        }
        return uploads
    }

    private func transfer(_ job: Job, uploads: [Upload], to config: DestinationConfig) async throws {
        let destination = dependencies.destinationFactory(config)
        try await destination.prepare()

        // Overall progress across all files, weighted by byte size.
        let sizes = uploads.map { Self.fileSize($0.url) }
        let totalBytes = sizes.reduce(0, +)
        var bytesDone: Int64 = 0
        let id = job.id
        job.transferRate = TransferRateEstimator()
        emitTransferProgress(job, doneBytes: 0, totalBytes: totalBytes)

        for (upload, size) in zip(uploads, sizes) {
            let baseDone = bytesDone
            try await destination.upload(file: upload.url, toRelativePath: upload.relativePath) { [weak self] progress in
                guard let self else { return }
                Task { await self.transferProgress(jobID: id, doneBytes: baseDone + progress.bytesSent, totalBytes: totalBytes) }
            }
            bytesDone += size
            emitTransferProgress(job, doneBytes: bytesDone, totalBytes: totalBytes)
            if let number = upload.trackNumber {
                updateTrack(job, number: number, status: .transferred)
            }
        }
        await destination.close()
    }

    private func complete(_ job: Job, deliveredTo destination: DestinationConfig) async {
        // For afterRip the disc was already ejected+released during the rip
        // stage, so we must NOT eject again here — by now a newly inserted
        // disc may already hold this same bsdName.
        if job.preferences.ejectTiming == .afterEverything {
            try? await dependencies.drive.eject(bsdName: job.bsdName)
            job.ejected = true
        }
        setStage(job, .completed)
        await jobStore.append(JobRecord(snapshot: job.snapshot))
        notify(title: "Album ready", body: "\(job.snapshot.displayTitle) → \(destination.displayName)")
        Self.removeStaging(job.stagingDir)
    }

    private func transferProgress(jobID: JobID, doneBytes: Int64, totalBytes: Int64) {
        guard let job = jobs[jobID] else { return }
        emitTransferProgress(job, doneBytes: doneBytes, totalBytes: totalBytes)
    }

    private func emitTransferProgress(_ job: Job, doneBytes: Int64, totalBytes: Int64) {
        guard job.transferRate.record(bytes: doneBytes) else { return } // stale tick
        let fraction = totalBytes > 0 ? Double(doneBytes) / Double(totalBytes) : 1
        eventContinuation.yield(.transferProgress(
            job.id, fraction: min(1, max(0, fraction)), bytesPerSecond: job.transferRate.bytesPerSecond
        ))
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
    }
}
