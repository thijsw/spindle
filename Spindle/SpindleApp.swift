import SpindleCore
import SwiftUI

@main
struct SpindleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Spindle") {
            MainView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 480)
                .task { model.start() }
        }
        .defaultSize(width: 820, height: 560)

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: menuBarBinding, content: {
            MenuBarContent()
                .environment(model)
        }, label: {
            Image(systemName: "opticaldisc")
        })
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { model.preferences.showMenuBarExtra },
            set: { model.preferences.showMenuBarExtra = $0 }
        )
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Reads only the coarse summary string (changes on stage
        // transitions), never the per-tick job snapshots — otherwise every
        // progress update rebuilds this NSStatusItem-backed scene and hangs
        // the app.
        Text(model.menuBarSummary)
        Divider()
        SettingsLink {
            Text("Settings…")
        }
        Button("Quit Spindle") {
            NSApplication.shared.terminate(nil)
        }
    }
}
