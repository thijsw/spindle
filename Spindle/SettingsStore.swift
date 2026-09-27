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
            do {
                try PreferencesStore.save(preferences)
            } catch {
                Logger(subsystem: "nl.huell.spindle", category: "settings")
                    .error("Could not save preferences: \(String(describing: error), privacy: .public)")
            }
            onChange?(preferences)
        }
    }

    /// Called (off the observation graph) when preferences change, so the
    /// AppModel can forward them to the pipeline coordinator.
    @ObservationIgnored var onChange: ((Preferences) -> Void)?

    init(_ preferences: Preferences) {
        self.preferences = preferences
    }
}
