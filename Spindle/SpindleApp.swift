import Sparkle
import SpindleCore
import SwiftUI

@main
struct SpindleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    // Owns the Sparkle updater for the app's lifetime. `startingUpdater: true`
    // begins the scheduled background checks (cadence from Info.plist).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        WindowGroup("Spindle") {
            MainView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 480)
                .task { model.start() }
        }
        .defaultSize(width: 820, height: 560)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }

        Settings {
            SettingsView()
                .environment(model.settings)
        }

        MenuBarExtra(isInserted: menuBarBinding, content: {
            MenuBarContent(updater: updaterController.updater)
                .environment(model)
        }, label: {
            Image(systemName: "opticaldisc")
        })
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { model.settings.preferences.showMenuBarExtra },
            set: { newValue in
                // SwiftUI drives this setter continuously; assigning even an
                // unchanged value notifies every preferences observer (and
                // re-renders the Settings panes), so write only on a real change.
                guard newValue != model.settings.preferences.showMenuBarExtra else { return }
                model.settings.preferences.showMenuBarExtra = newValue
            }
        )
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    let updater: SPUUpdater

    var body: some View {
        // Reads only the coarse summary string (changes on stage
        // transitions), never the per-tick job snapshots — otherwise every
        // progress update rebuilds this NSStatusItem-backed scene and hangs
        // the app.
        Text(model.menuBarSummary)
        Divider()
        CheckForUpdatesView(updater: updater)
        SettingsLink {
            Text("Settings…")
        }
        Button("Quit Spindle") {
            NSApplication.shared.terminate(nil)
        }
    }
}
