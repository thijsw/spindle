import AppKit
import DiscDrive
import Encoding
import Metadata
import Naming
import SpindleCore
import SwiftUI
import Transfer

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
        // A fixed height with internally-scrolling forms: the Destination
        // pane (SFTP fields + footers) is the tallest and was clipping.
        .frame(width: 560, height: 560)
    }
}

// MARK: - General

struct GeneralSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("FLAC", isOn: formatBinding(.flac))
                Toggle("Apple Lossless (ALAC)", isOn: formatBinding(.alac))
            } header: {
                Text("Formats")
            } footer: {
                Text("FLAC is ideal for Navidrome and most servers; ALAC plays natively in Apple apps.")
                    .settingsFooter()
            }

            Section("File names") {
                TextField("Template", text: $model.preferences.namingTemplate.template)
                    .font(.system(.body, design: .monospaced))
                Text(namingPreview)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("Tokens: {albumartist} {album} {artist} {title} {track} {disc} {year} {originalyear}. Square brackets drop their content when a token inside is empty.")
                    .settingsFooter()
            }

            Section("Behavior") {
                Picker("Eject the disc", selection: $model.preferences.ejectTiming) {
                    Text("As soon as audio is copied").tag(Preferences.EjectTiming.afterRip)
                    Text("After encoding and transfer finish").tag(Preferences.EjectTiming.afterEverything)
                }
                Toggle("Show notifications", isOn: $model.preferences.notificationsEnabled)
                Toggle("Show menu bar status", isOn: $model.preferences.showMenuBarExtra)
            }
        }
        .formStyle(.grouped)
    }

    private func formatBinding(_ format: AudioFormat) -> Binding<Bool> {
        Binding(
            get: { model.preferences.formats.contains(format) },
            set: { include in
                var formats = model.preferences.formats.filter { $0 != format }
                if include { formats.append(format) }
                if formats.isEmpty { formats = [.flac] } // never zero formats
                model.preferences.formats = formats.sorted { $0.rawValue < $1.rawValue }
            }
        )
    }

    private var namingPreview: String {
        var album = ResolvedAlbum.fallback(cdText: nil, discID: nil, trackCount: 1)
        album.album = "Hello Nasty"
        album.albumArtist = "Beastie Boys"
        album.date = "1998-07-14"
        var track = album.tracks[0]
        track.title = "Intergalactic"
        track.position = 7
        return "Preview: " + model.preferences.namingTemplate.render(album: album, track: track) + ".flac"
    }
}

// MARK: - Destination

struct DestinationSettingsPane: View {
    @Environment(AppModel.self) private var model

    private enum Kind: String, CaseIterable {
        case none = "None"
        case folder = "Local Folder"
        case sftp = "SFTP Server"
    }

    @State private var folderPath = ""
    @State private var sftpHost = ""
    @State private var sftpPort = 22
    @State private var sftpUser = ""
    @State private var sftpRemotePath = ""
    @State private var sftpPassword = ""
    @State private var sftpKeyFile = ""
    @State private var usesKeyFile = false
    @State private var testResult: String?
    @State private var testFailed = false
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                Picker("Deliver music to", selection: kindBinding) {
                    ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("A local folder also covers NAS shares mounted in Finder (SMB/NFS/WebDAV). SFTP reaches any SSH server — like a Navidrome host.")
                    .settingsFooter()
            }

            switch kind {
            case .none:
                EmptyView()
            case .folder:
                Section("Folder") {
                    HStack {
                        TextField("Path", text: $folderPath, prompt: Text("/Volumes/Music"))
                            .onSubmit(applyFolder)
                        Button("Choose…", action: chooseFolder)
                    }
                }
            case .sftp:
                sftpSection
            }

            if kind != .none {
                Section {
                    HStack {
                        Button(action: runTest) {
                            if testing {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Test Connection")
                            }
                        }
                        .disabled(testing)
                        if let testResult {
                            Label(testResult, systemImage: testFailed ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(testFailed ? .red : .green)
                                .font(.callout)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(loadFromPreferences)
    }

    @ViewBuilder private var sftpSection: some View {
        Section("Server") {
            TextField("Host", text: $sftpHost, prompt: Text("navidrome.example.com"))
                .onSubmit(applySFTP)
            TextField("Port", value: $sftpPort, format: .number.grouping(.never))
                .onSubmit(applySFTP)
            TextField("User", text: $sftpUser)
                .onSubmit(applySFTP)
            TextField("Music folder on the server", text: $sftpRemotePath, prompt: Text("/srv/music"))
                .onSubmit(applySFTP)
        }
        Section("Authentication") {
            Picker("Method", selection: $usesKeyFile) {
                Text("Password").tag(false)
                Text("SSH key file").tag(true)
            }
            if usesKeyFile {
                HStack {
                    TextField("Private key", text: $sftpKeyFile, prompt: Text("~/.ssh/id_ed25519"))
                    Button("Choose…", action: chooseKeyFile)
                }
                SecureField("Key passphrase (if any)", text: $sftpPassword)
                    .onSubmit(applySFTP)
            } else {
                SecureField("Password", text: $sftpPassword)
                    .onSubmit(applySFTP)
            }
            Text("The secret is stored in your Keychain, never in preference files.")
                .settingsFooter()
        }
    }

    private var kind: Kind {
        switch model.preferences.destination {
        case nil: .none
        case .localFolder: .folder
        case .sftp: .sftp
        }
    }

    private var kindBinding: Binding<Kind> {
        Binding(
            get: { kind },
            set: { newKind in
                testResult = nil
                switch newKind {
                case .none:
                    model.preferences.destination = nil
                case .folder:
                    model.preferences.destination = .localFolder(path: folderPath)
                case .sftp:
                    applySFTP()
                }
            }
        )
    }

    @Sendable private func loadFromPreferences() async {
        switch model.preferences.destination {
        case .localFolder(let path):
            folderPath = path
        case .sftp(let config):
            sftpHost = config.host
            sftpPort = config.port
            sftpUser = config.username
            sftpRemotePath = config.remotePath
            if case .privateKeyFile(let path) = config.authentication {
                usesKeyFile = true
                sftpKeyFile = path
            }
            // SecItemCopyMatching blocks the calling thread until any
            // Keychain access dialog is answered — never on the main thread.
            let account = config.keychainAccount
            sftpPassword = await Task.detached(priority: .utility) {
                KeychainStore.load(account: account) ?? ""
            }.value
        case nil:
            break
        }
    }

    private func applyFolder() {
        model.preferences.destination = .localFolder(path: folderPath)
    }

    private func applySFTP() {
        guard !sftpHost.isEmpty, !sftpUser.isEmpty else { return }
        let config = SFTPConfig(
            host: sftpHost,
            port: sftpPort,
            username: sftpUser,
            authentication: usesKeyFile ? .privateKeyFile(path: sftpKeyFile) : .password,
            remotePath: sftpRemotePath.isEmpty ? "." : sftpRemotePath
        )
        if !sftpPassword.isEmpty {
            try? KeychainStore.save(secret: sftpPassword, account: config.keychainAccount)
        }
        model.preferences.destination = .sftp(config)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
            applyFolder()
        }
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            sftpKeyFile = url.path
            applySFTP()
        }
    }

    private func runTest() {
        if kind == .folder { applyFolder() } else { applySFTP() }
        guard let config = model.preferences.destination else { return }
        testing = true
        testResult = nil
        let secret = sftpPassword.isEmpty ? nil : sftpPassword
        Task {
            let destination: any Destination = switch config {
            case .localFolder(let path): LocalFolderDestination(path: path)
            case .sftp(let sftpConfig): SFTPDestination(config: sftpConfig, secret: secret)
            }
            let result = await destination.test()
            await destination.close()
            switch result {
            case .success(let message):
                testResult = message
                testFailed = false
            case .failure(let error):
                testResult = String(describing: error)
                testFailed = true
            }
            testing = false
        }
    }
}

// MARK: - Ripping

struct RippingSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var driveName: String?
    @State private var driveKey: String?
    @State private var suggestedOffset: Int?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Mode", selection: $model.preferences.ripMode) {
                    Text("Secure (re-read on errors)").tag(Preferences.RipMode.secure)
                    Text("Fast (single pass)").tag(Preferences.RipMode.fast)
                }
                Stepper(
                    "Re-read attempts: \(model.preferences.maxRetries)",
                    value: $model.preferences.maxRetries,
                    in: 2...64
                )
                .disabled(model.preferences.ripMode == .fast)
            } header: {
                Text("Accuracy")
            } footer: {
                Text("Secure mode re-reads sectors the drive flags as damaged until consecutive reads agree, and verifies the result against the CUETools database.")
                    .settingsFooter()
            }

            Section {
                if let driveKey {
                    TextField(
                        "Offset for \(driveName ?? driveKey) (samples)",
                        value: Binding(
                            get: { model.preferences.driveOffsets[driveKey] ?? 0 },
                            set: { model.preferences.driveOffsets[driveKey] = $0 }
                        ),
                        format: .number
                    )
                    if let suggestedOffset, model.preferences.driveOffsets[driveKey] == nil {
                        Button("Use typical value for this drive family (+\(suggestedOffset))") {
                            model.preferences.driveOffsets[driveKey] = suggestedOffset
                        }
                        .controlSize(.small)
                    }
                } else {
                    Text("Insert a disc to configure the drive's read offset.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Drive read offset")
            } footer: {
                Text("Each drive model reads a fixed number of samples early or late. Setting the AccurateRip-style offset makes rips byte-identical with other rippers. A CTDB-verified rip confirms the value is right.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .task(detectDrive)
    }

    /// IOKit registry traversal is synchronous and can stall for seconds
    /// while a rip is holding the drive — so it must never run on the main
    /// thread, or the whole app beach-balls.
    @Sendable private func detectDrive() async {
        let found = await Task.detached(priority: .utility) { () -> (String, String, Int?)? in
            guard let bsd = DiscDrive.DiscEnumerator.presentCDMedia().first,
                  let identity = DiscDrive.DiscEnumerator.driveIdentity(forMediaBSDName: bsd)
            else { return nil }
            return (identity.displayName, identity.offsetKey, DiscDrive.DriveOffsetTable.suggestion(for: identity)?.samples)
        }.value
        guard let found else { return }
        driveName = found.0
        driveKey = found.1
        suggestedOffset = found.2
    }
}

// MARK: - Metadata

struct MetadataSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Pick the best match automatically", isOn: $model.preferences.autoPickRelease)
                Text("When off — or when matches are too close to call — Spindle asks you to choose, without interrupting the rip.")
                    .settingsFooter()
            }

            Section("Preferred countries") {
                TextField(
                    "Country codes",
                    text: Binding(
                        get: { model.preferences.metadata.preferredCountries.joined(separator: ", ") },
                        set: {
                            model.preferences.metadata.preferredCountries = $0
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                                .filter { !$0.isEmpty }
                        }
                    ),
                    prompt: Text("NL, DE, GB, US")
                )
                Text("Used to rank pressings when several releases match.")
                    .settingsFooter()
            }

            Section("Cover art") {
                Picker("Embedded size", selection: $model.preferences.coverArtSize) {
                    Text("500 px").tag(CoverArtSize.medium)
                    Text("1200 px").tag(CoverArtSize.large)
                    Text("Original").tag(CoverArtSize.original)
                }
                Toggle("Also save cover.jpg in each album folder", isOn: $model.preferences.writeCoverJPEG)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Helpers

extension Text {
    func settingsFooter() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}


