import SpindleCore
import SwiftUI

@main
struct SpindleApp: App {
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
        if let job = model.activeJob {
            Text(job.displayTitle)
            Text(job.stage.label)
        } else {
            Text("Waiting for a disc")
        }
        Divider()
        ForEach(model.backgroundJobs) { job in
            Text("\(job.displayTitle) — \(job.stage.label)")
        }
        if !model.backgroundJobs.isEmpty {
            Divider()
        }
        SettingsLink {
            Text("Settings…")
        }
        Button("Quit Spindle") {
            NSApplication.shared.terminate(nil)
        }
    }
}
