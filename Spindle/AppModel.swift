import AppKit
import Foundation
import ImageIO
import Metadata
import Observation
import SpindleCore
import UserNotifications

@MainActor
@Observable
final class AppModel {
    private(set) var jobs: [JobSnapshot] = []
    /// Cover art decoded exactly once per job (never in a SwiftUI body).
    private(set) var coverArt: [JobID: NSImage] = [:]

    func coverArt(for id: JobID) -> NSImage? { coverArt[id] }

    /// A coarse one-line status for the menu bar. The menu bar is a Scene
    /// backed by an NSStatusItem, and rebuilding that scene is expensive — so
    /// it must observe ONLY this string, which is reassigned just on stage
    /// transitions, never on per-fraction progress ticks. (Letting the menu
    /// read `jobs` directly rebuilt the status item ~every tick and hung the
    /// whole app whenever a second window was also open.)
    private(set) var menuBarSummary = "Waiting for a disc"

    private func refreshMenuBarSummary() {
        let active = jobs.filter { !$0.stage.isTerminal }
        let summary: String
        if let job = active.last {
            summary = "\(job.displayTitle) — \(job.stage.label)"
        } else {
            summary = "Waiting for a disc"
        }
        if summary != menuBarSummary { menuBarSummary = summary }
    }
    private(set) var history: [JobRecord] = []
    private(set) var startupError: String?

    /// Preferences live in their own observable so the Settings window never
    /// re-renders on rip churn. Convenience accessor for AppModel-internal use.
    let settings: SettingsStore
    private var preferences: Preferences { settings.preferences }

    /// Destination label for the idle screen.
    var destinationSummary: String? { settings.preferences.destination?.displayName }

    /// Job whose release picker should be shown (nil hides the sheet).
    var pickerJobID: JobID?

    /// Open manual tag-editing session (nil hides the sheet).
    var tagEditorSession: TagEditorSession?
    /// Jobs paused for hand-edited tags, so the toolbar can offer to reopen
    /// the editor after the sheet was cancelled.
    private(set) var jobsNeedingTags: Set<JobID> = []

    private var coordinator: PipelineCoordinator?
    private var jobStore: JobStore?
    private let powerAssertion = PowerAssertion()

    init() {
        self.settings = SettingsStore(PreferencesStore.load())
        self.settings.onChange = { [weak self] prefs in
            guard let coordinator = self?.coordinator else { return }
            Task { await coordinator.updatePreferences(prefs) }
        }
    }

    var hasActiveJobs: Bool {
        jobs.contains { !$0.stage.isTerminal }
    }

    /// The job the main window focuses on: the most recent non-terminal one.
    var activeJob: JobSnapshot? {
        jobs.last { !$0.stage.isTerminal }
    }

    /// Jobs still working off the rip lane (encoding/transferring).
    var backgroundJobs: [JobSnapshot] {
        jobs.filter { !$0.stage.isTerminal && $0.id != activeJob?.id }
    }

    var pickerJob: JobSnapshot? {
        pickerJobID.flatMap { id in jobs.first { $0.id == id } }
    }

    /// Live upload fraction (0...1) and throughput (bytes/sec) per job.
    private(set) var transferFraction: [JobID: Double] = [:]
    private(set) var transferRate: [JobID: Double] = [:]

    /// One-line description of what the app is doing right now, for the
    /// status bar. Prefers the most downstream activity (uploading), so the
    /// user sees the step that's actually taking time.
    var statusText: String {
        let active = jobs.filter { !$0.stage.isTerminal }
        guard !active.isEmpty else {
            return settings.preferences.destination == nil
                ? "No destination set — open Settings"
                : "Ready — insert a disc"
        }
        func title(_ job: JobSnapshot) -> String { job.album?.album ?? "Audio CD" }

        if let job = active.first(where: { $0.stage == .transferring }) {
            let pct = Int((transferFraction[job.id] ?? 0) * 100)
            let bps = transferRate[job.id] ?? 0
            let speed = bps > 0 ? " · \(Self.formatRate(bps))" : ""
            return "Uploading \(title(job)) — \(pct)%\(speed)"
        }
        if let job = active.first(where: { $0.stage == .encoding }) {
            return "Encoding \(title(job))"
        }
        if let job = activeJob {
            if job.stage == .ripping, let detail = rippingTrackDetail(job) {
                return "Ripping \(title(job)) — \(detail)"
            }
            return "\(job.stage.label) — \(title(job))"
        }
        return active[0].stage.label
    }

    /// "track N of M" for the track currently being read, or nil.
    private func rippingTrackDetail(_ job: JobSnapshot) -> String? {
        guard let current = job.tracks.first(where: {
            if case .ripping = $0.status { return true } else { return false }
        }) else { return nil }
        return "track \(current.number) of \(job.tracks.count)"
    }

    private static func formatRate(_ bytesPerSecond: Double) -> String {
        let mb = bytesPerSecond / 1_000_000
        if mb >= 1 { return String(format: "%.1f MB/s", mb) }
        return String(format: "%.0f KB/s", bytesPerSecond / 1000)
    }

    /// Upload fraction to show as a determinate bar, or nil to show a spinner.
    var statusProgress: Double? {
        guard let job = jobs.first(where: { $0.stage == .transferring }) else { return nil }
        return transferFraction[job.id]
    }

    /// Whether to show activity (spinner / bar) in the status area.
    var isBusy: Bool { hasActiveJobs }

    func start() {
        guard coordinator == nil else { return }
        AppDelegate.hasActiveWork = { [weak self] in self?.hasActiveJobs ?? false }
        cleanUpStaleStaging()
        do {
            let store = JobStore()
            let coordinator = PipelineCoordinator(
                preferences: preferences,
                dependencies: try .live(userAgent: Spindle.userAgent),
                jobStore: store
            )
            self.coordinator = coordinator
            self.jobStore = store

            Task { [weak self] in
                await coordinator.start()
                await self?.refreshHistory()
                for await event in coordinator.events {
                    self?.handle(event)
                }
            }
            requestNotificationPermission()
        } catch {
            startupError = String(describing: error)
        }
    }

    private func handle(_ event: PipelineEvent) {
        switch event {
        case .jobUpdated(let snapshot):
            if let index = jobs.firstIndex(where: { $0.id == snapshot.id }) {
                jobs[index] = snapshot
            } else {
                jobs.append(snapshot)
            }
            if snapshot.album != nil || snapshot.stage.isTerminal {
                jobsNeedingTags.remove(snapshot.id)
            }
            if snapshot.stage.isTerminal {
                if pickerJobID == snapshot.id { pickerJobID = nil }
                if tagEditorSession?.jobID == snapshot.id { tagEditorSession = nil }
                transferFraction[snapshot.id] = nil
                transferRate[snapshot.id] = nil
                coverArt[snapshot.id] = nil
                Task { await self.refreshHistory() }
            }
            refreshMenuBarSummary()
            // Keep the Mac awake while any disc is in flight.
            if hasActiveJobs {
                powerAssertion.activate()
            } else {
                powerAssertion.release()
            }

        case .releaseChoiceNeeded(let jobID):
            // Don't steal focus while another picker is open.
            if pickerJobID == nil, tagEditorSession == nil { pickerJobID = jobID }

        case .tagsNeeded(let jobID):
            jobsNeedingTags.insert(jobID)
            if pickerJobID == nil, tagEditorSession == nil {
                openTagEditor(jobID: jobID, candidateID: nil)
            }

        case .notify(let title, let body):
            postNotification(title: title, body: body)

        case .transferProgress(let jobID, let fraction, let bytesPerSecond):
            transferFraction[jobID] = fraction
            transferRate[jobID] = bytesPerSecond

        case .artLoaded(let jobID, let data):
            // Decode AND downscale once, off the main thread. The original is
            // ~1200 px; displayed at 220 pt it would otherwise be resampled
            // from 1.4 MP on every render (cover art re-renders with each
            // progress tick), which pegs the main thread. A 480 px thumbnail
            // resamples in microseconds. (FLAC embedding uses the raw bytes,
            // not this image, so the thumbnail loses nothing.)
            Task {
                let image = await Task.detached(priority: .userInitiated) {
                    Self.thumbnail(from: data, maxPixel: 480)
                }.value
                if let image { coverArt[jobID] = image }
            }

        case .c2Unreliable(let driveKey):
            // SettingsStore.didSet persists and informs the coordinator.
            settings.preferences.markC2Unreliable(forDrive: driveKey)
        }
    }

    func choose(candidateID: String) {
        guard let jobID = pickerJobID, let coordinator else { return }
        pickerJobID = nil
        Task { await coordinator.chooseRelease(jobID: jobID, candidateID: candidateID) }
    }

    func declinePicker() {
        guard let jobID = pickerJobID, let coordinator else { return }
        pickerJobID = nil
        Task { await coordinator.declineReleaseChoice(jobID: jobID) }
    }

    // MARK: Manual tag editing

    /// Opens the tag editor for a job, pre-filled from `candidateID` (when
    /// coming from the picker) or from CD-TEXT/fallback tags.
    func openTagEditor(jobID: JobID, candidateID: String?) {
        guard let coordinator else { return }
        pickerJobID = nil
        Task {
            guard let draft = await coordinator.tagEditorDraft(jobID: jobID, candidateID: candidateID)
            else { return }
            let durations = (jobs.first { $0.id == jobID }?.tracks ?? [])
                .reduce(into: [Int: Double]()) { $0[$1.number] = $1.durationSeconds }
            tagEditorSession = TagEditorSession(jobID: jobID, draft: draft, durations: durations)
        }
    }

    func submitTags(_ album: ResolvedAlbum) {
        guard let session = tagEditorSession, let coordinator else { return }
        tagEditorSession = nil
        jobsNeedingTags.remove(session.jobID)
        Task { await coordinator.provideTags(jobID: session.jobID, album: album) }
    }

    /// Dismisses the editor without resolving. A job with candidates falls
    /// back to its picker; an unknown disc stays paused — the toolbar offers
    /// to reopen the editor.
    func cancelTagEditor() {
        guard let session = tagEditorSession else { return }
        tagEditorSession = nil
        if let job = jobs.first(where: { $0.id == session.jobID }),
           job.album == nil, !job.candidates.isEmpty {
            pickerJobID = session.jobID
        }
    }

    /// Staging directories survive crashes; anything present at launch is an
    /// orphan (no rip is resumable across launches in v1).
    private func cleanUpStaleStaging() {
        let staging = PreferencesStore.applicationSupportURL.appendingPathComponent("Staging")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Decodes image bytes and downscales to fit `maxPixel`, preserving
    /// aspect ratio. Returns a bitmap-backed NSImage cheap to draw.
    nonisolated private static func thumbnail(from data: Data, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func refreshHistory() async {
        guard let jobStore else { return }
        history = await jobStore.history()
    }

    // MARK: Notifications (only available inside a real .app bundle)

    private var notificationsAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    private func requestNotificationPermission() {
        guard notificationsAvailable, preferences.notificationsEnabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postNotification(title: String, body: String) {
        guard preferences.notificationsEnabled else { return }
        guard notificationsAvailable else {
            NSSound.beep()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
