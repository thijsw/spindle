import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            DestinationSettingsPane()
                .tabItem { Label("Destination", systemImage: "externaldrive.connected.to.line.below") }
            RippingSettingsPane()
                .tabItem { Label("Ripping", systemImage: "opticaldisc") }
            MetadataSettingsPane()
                .tabItem { Label("Metadata", systemImage: "music.note.list") }
        }
        // A fixed height with internally-scrolling forms; must fit the
        // tallest pane (General, since the album-folder-extras section)
        // or it grows a scroll bar.
        .frame(width: 560, height: 720)
    }
}

// MARK: - Helpers shared by the panes

extension Text {
    func settingsFooter() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Modal file/folder pickers, one place for the NSOpenPanel boilerplate.
@MainActor
enum FilePicker {
    static func chooseFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFile(in directory: URL?, showsHiddenFiles: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.showsHiddenFiles = showsHiddenFiles
        panel.directoryURL = directory
        return panel.runModal() == .OK ? panel.url : nil
    }
}
