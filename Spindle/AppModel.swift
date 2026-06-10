import AppKit
import Foundation
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
    private(set) var history: [JobRecord] = []
    private(set) var startupError: String?

    var preferences: Preferences {
        didSet {
            guard preferences != oldValue else { return }
            PreferencesStore.save(preferences)
            let coordinator = self.coordinator
            let preferences = self.preferences
            Task { await coordinator?.updatePreferences(preferences) }
        }
    }

    /// Job whose release picker should be shown (nil hides the sheet).
    var pickerJobID: JobID?

    private var coordinator: PipelineCoordinator?
    private var jobStore: JobStore?
    private let powerAssertion = PowerAssertion()

    init() {
        self.preferences = PreferencesStore.load()
    }

    var hasActiveJobs: Bool {
        jobs.contains { !$0.stage.isTerminal }
    }

    /// The job the main window focuses on: the most recent non-terminal one.
    var activeJob: JobSnapshot? {
        jobs.last { !$0.stage.isTerminal }
    }

    /// Jobs still working in the background plus recent history chips.
    var backgroundJobs: [JobSnapshot] {
        jobs.filter { !$0.stage.isTerminal && $0.id != activeJob?.id }
    }

    var pickerJob: JobSnapshot? {
        pickerJobID.flatMap { id in jobs.first { $0.id == id } }
    }

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
            if snapshot.stage.isTerminal {
                if pickerJobID == snapshot.id { pickerJobID = nil }
                Task { await self.refreshHistory() }
            }
            // Keep the Mac awake while any disc is in flight.
            if hasActiveJobs {
                powerAssertion.activate()
            } else {
                powerAssertion.release()
            }

        case .releaseChoiceNeeded(let jobID):
            // Don't steal focus while another picker is open.
            if pickerJobID == nil { pickerJobID = jobID }

        case .notify(let title, let body):
            postNotification(title: title, body: body)

        case .artLoaded(let jobID, let data):
            // Decode the JPEG once, off the main thread, then cache the image.
            Task {
                let image = await Task.detached(priority: .userInitiated) {
                    NSImage(data: data)
                }.value
                if let image { coverArt[jobID] = image }
            }

        case .c2Unreliable(let driveKey):
            // Persisting via the preferences didSet also informs the coordinator.
            preferences.markC2Unreliable(forDrive: driveKey)
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
