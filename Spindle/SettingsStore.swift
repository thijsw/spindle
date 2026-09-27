import Foundation
import Observation
import SpindleCore
import os

/// Holds user preferences in isolation from the rip pipeline.
///
/// The Settings window observes ONLY this object. Preferences change rarely
/// (user edits), so while a rip hammers `AppModel` with job/art updates, the
/// Settings panes — and their expensive `Picker` pop-up menus — never
/// re-render. Mixing preferences into the same `@Observable` as the live job
/// state caused SwiftUI to re-evaluate the Settings panes on every progress
/// tick and hang the app.
@MainActor
@Observable
final class SettingsStore {
    var preferences: Preferences {
        didSet {
            guard preferences != oldValue else { return }
            onChange?(preferences)
            scheduleSave()
        }
    }

    /// Called (off the observation graph) when preferences change, so the
    /// AppModel can forward them to the pipeline coordinator.
    @ObservationIgnored var onChange: ((Preferences) -> Void)?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    init(_ preferences: Preferences) {
        self.preferences = preferences
    }

    /// Text fields write on every keystroke; coalesce the disk writes and
    /// keep them off the main thread.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [preferences] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            Self.write(preferences)
        }
    }

    /// Writes any pending change immediately (call before quitting).
    func flush() {
        guard pendingSave != nil else { return }
        pendingSave?.cancel()
        pendingSave = nil
        Self.write(preferences)
    }

    private static func write(_ preferences: Preferences) {
        do {
            try PreferencesStore.save(preferences)
        } catch {
            Logger(subsystem: "nl.huell.spindle", category: "settings")
                .error("Could not save preferences: \(String(describing: error), privacy: .public)")
        }
    }
}
