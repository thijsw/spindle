import Sparkle
import SwiftUI

/// Publishes the updater's `canCheckForUpdates` so the "Check for Updates…"
/// menu item enables and disables in step with Sparkle's own state (it can't
/// check while an update is already in flight). Main-actor isolated because
/// Sparkle's `canCheckForUpdates` is itself main-actor isolated.
@MainActor
final class UpdaterViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// A menu command that triggers a manual update check. Used both in the app's
/// menu bar (under the app menu) and in the `MenuBarExtra` status menu.
struct CheckForUpdatesView: View {
    @StateObject private var viewModel: UpdaterViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        _viewModel = StateObject(wrappedValue: UpdaterViewModel(updater: updater))
    }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!viewModel.canCheckForUpdates)
    }
}
