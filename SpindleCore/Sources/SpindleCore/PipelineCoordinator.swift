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
        /// Set once the physical disc has left the drive. After this point a
        /// disc reappearing on the same `bsdName` is a *different* disc, so it
        /// must not be deduplicated against this (still-processing) job.
        var ejected = false
        var snapshot: JobSnapshot
        var toc: TOC?
        var discTOC: DiscTOC?
        var cdText: CDTextInfo?
        var rankedReleases: [ReleaseScorer.Ranked] = []
        var rippedTracks: [RippedTrack] = []
        // Rip provenance, kept for the archival log written at encode time.
        var ripOutcome: VerifiedRipper.Outcome?
        var ripConfig: RipConfiguration?
        var driveIdentity: DriveIdentity?
        var ripDuration: Duration?
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
                hasArt: false,
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
        if let album = ResolvedAlbum(
            release: ranked.release,
            discID: job.discTOC?.musicBrainzDiscID,
            audioTrackCount: toc.audioTracks.count
        ) {
            resolve(job: job, album: album)
        } else {
            resolve(job: job, album: fallbackAlbum(for: job, trackCount: toc.audioTracks.count))
        }
    }

    /// Fallback when the user dismisses the picker: tag from CD-TEXT/unknown.
    public func declineReleaseChoice(jobID: JobID) {
        guard let job = jobs[jobID], let toc = job.toc else { return }
        resolve(job: job, album: fallbackAlbum(for: job, trackCount: toc.audioTracks.count))
    }

    public func currentSnapshots() -> [JobSnapshot] {
        jobs.values.map(\.snapshot).sorted { $0.startedAt < $1.startedAt }
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
        let job = Job(bsdName: bsd, stagingRoot: dependencies.stagingRoot)
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
        // Only release if we still hold the drive. If the disc already ejected
        // (afterRip failure during encode/upload), a new disc may now hold this
        // bsdName — releasing would drop its mount protection.
        if !job.ejected {
            dependencies.drive.release(bsdName: job.bsdName)
        }
    }

    /// CD-TEXT/unknown tagging for discs MusicBrainz can't (or wasn't allowed
    /// to) resolve.
    private func fallbackAlbum(for job: Job, trackCount: Int) -> ResolvedAlbum {
        .fallback(
            cdText: job.cdText,
            discID: job.discTOC?.musicBrainzDiscID,
            trackCount: trackCount
        )
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
            job.rippedTracks = outcome.tracks
            job.ripOutcome = outcome
            job.ripConfig = config
            job.driveIdentity = identity
            job.ripDuration = ContinuousClock.now - ripStarted
            job.snapshot.verificationSummary = outcome.verification?.summary ?? outcome.strategy
            if outcome.c2Unreliable, let identity {
                eventContinuation?.yield(.c2Unreliable(driveKey: identity.offsetKey))
            }
            for number in outcome.failedTracks {
                updateTrack(job, number: number, status: .failed("Unreadable — gave up after the time limit"))
            }
            if !outcome.failedTracks.isEmpty {
                eventContinuation?.yield(.notify(
                    title: "Some tracks could not be read",
                    body: "\(job.snapshot.displayTitle): track(s) \(outcome.failedTracks.map(String.init).joined(separator: ", ")) were skipped."
                ))
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
            setStage(job, .ripped)

            // Close the raw device before ejecting — an open /dev/rdiskN
            // keeps the disc busy and DADiskEject fails silently.
            await device.close()

            if preferences.ejectTiming == .afterRip {
                try? await dependencies.drive.eject(bsdName: job.bsdName)
                job.ejected = true // a disc now inserted here is a new disc
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
        // Throttle the live percentage to ~4 Hz. This re-renders the main
        // window's track table (cheap), but must NOT churn the menu-bar
        // scene — see AppModel.menuBarSummary, which only changes on coarse
        // stage transitions, not on these ticks.
        let now = ContinuousClock.now
        guard now - lastProgressUpdate > .milliseconds(250) || progress.fraction >= 1 else { return }
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
            resolve(job: job, album: fallbackAlbum(for: job, trackCount: toc.audioTracks.count))
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
                job.snapshot.hasArt = true
                publish(job)
                // Bytes out of band: the snapshot stays small and cheap.
                eventContinuation?.yield(.artLoaded(job.id, art.data))
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
        guard let job = jobs[jobID] else { return }
        // Verification already happened inside the verify-first rip
        // (drive-bound, so failed tracks could be re-ripped before eject).

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
            var trackFiles: [Int: String] = [:] // position → relative path

            let format = preferences.format
            let encoder = format.makeEncoder()
            for ripped in job.rippedTracks {
                let position = trackPosition(of: ripped, in: job)
                guard let track = album.tracks.first(where: { $0.position == position }) else {
                    continue
                }
                let tags = TrackTags(album: album, track: track)
                let relative = preferences.namingTemplate.render(album: album, track: track)
                    + "." + format.fileExtension
                let target = encodedDir.appendingPathComponent(relative)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try await encoder.encode(wav: ripped.wavURL, to: target, tags: tags, art: job.art)
                uploads.append((target, relative))
                albumFolders.insert((relative as NSString).deletingLastPathComponent)
                trackFiles[position] = relative
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

            // Archival artifacts, named "<Artist> - <Album>" like EAC's.
            if preferences.writeRipLog || preferences.writeCueSheet,
               let outcome = job.ripOutcome, let toc = job.toc {
                let baseName = PathSanitizer.component("\(album.albumArtist) - \(album.album)")
                for folder in albumFolders {
                    func emit(_ contents: String, _ ext: String) {
                        let relative = folder.isEmpty ? "\(baseName).\(ext)" : "\(folder)/\(baseName).\(ext)"
                        let url = encodedDir.appendingPathComponent(relative)
                        guard (try? contents.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
                        uploads.append((url, relative))
                    }
                    if preferences.writeRipLog {
                        emit(RipLog(
                            ripDate: Date(),
                            drive: job.driveIdentity,
                            configuration: job.ripConfig ?? RipConfiguration(),
                            toc: toc,
                            discTOC: job.discTOC,
                            album: album,
                            outcome: outcome,
                            ripDuration: job.ripDuration
                        ).render(), "log")
                    }
                    if preferences.writeCueSheet {
                        // Only the tracks whose files live in this folder.
                        let names = trackFiles.compactMapValues { relative -> String? in
                            (relative as NSString).deletingLastPathComponent == folder
                                ? (relative as NSString).lastPathComponent : nil
                        }
                        emit(CueSheet.render(
                            album: album,
                            toc: toc,
                            discTOC: job.discTOC,
                            fileNames: names,
                            comment: "Spindle \(RipLog.currentAppVersion)"
                        ), "cue")
                    }
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

            // Overall upload progress across all files, weighted by byte size.
            let totalBytes = uploads.reduce(Int64(0)) { $0 + Self.fileSize($1.0) }
            var bytesDone: Int64 = 0
            let id = job.id
            transferRate = nil
            emitTransferProgress(id, doneBytes: 0, totalBytes: totalBytes)

            for (url, relative) in uploads {
                let baseDone = bytesDone
                try await destination.upload(file: url, toRelativePath: relative) { [weak self] progress in
                    guard let self else { return }
                    Task { await self.emitTransferProgress(id, doneBytes: baseDone + progress.bytesSent, totalBytes: totalBytes) }
                }
                bytesDone += Self.fileSize(url)
                emitTransferProgress(id, doneBytes: bytesDone, totalBytes: totalBytes)
                if let number = trackNumber(fromRelativePath: relative, album: album) {
                    updateTrack(job, number: number, status: .transferred)
                }
            }
            await destination.close()

            // Done. (eject releases the DiskArbitration hold internally; for
            // afterRip the disc was already ejected+released during the rip
            // stage, so we must NOT release again here — by now a newly
            // inserted disc may already hold this same bsdName.)
            if preferences.ejectTiming == .afterEverything {
                try? await dependencies.drive.eject(bsdName: job.bsdName)
                job.ejected = true
            }
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

    /// Smoothed transfer-rate estimator for the active upload.
    private var transferRate: (lastBytes: Int64, lastTime: ContinuousClock.Instant, bps: Double)?

    private func emitTransferProgress(_ id: JobID, doneBytes: Int64, totalBytes: Int64) {
        let fraction = totalBytes > 0 ? Double(doneBytes) / Double(totalBytes) : 1
        let now = ContinuousClock.now
        var bps = transferRate?.bps ?? 0
        if let rate = transferRate {
            let dt = Double((now - rate.lastTime).components.seconds)
                + Double((now - rate.lastTime).components.attoseconds) / 1e18
            if dt > 0.05 { // ignore sub-50ms ticks; jitter swamps the estimate
                let instant = Double(doneBytes - rate.lastBytes) / dt
                bps = rate.bps == 0 ? instant : rate.bps * 0.7 + instant * 0.3 // EMA
                transferRate = (doneBytes, now, bps)
            }
        } else {
            transferRate = (doneBytes, now, 0)
        }
        eventContinuation?.yield(.transferProgress(id, fraction: min(1, max(0, fraction)), bytesPerSecond: bps))
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64).flatMap { $0 } ?? 0
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
