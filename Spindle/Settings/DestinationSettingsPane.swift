import SpindleCore
import SwiftUI
import Transfer

struct DestinationSettingsPane: View {
    @Environment(SettingsStore.self) private var model

    /// Form state, loaded from preferences once; edits apply on submit.
    @State private var draft = DestinationDraft(nil)
    @State private var password = ""
    @State private var loaded = false
    @State private var test = ConnectionTest.idle

    private enum ConnectionTest {
        case idle, running
        case finished(message: String, failed: Bool)
    }

    var body: some View {
        Form {
            Section {
                Picker("Deliver music to", selection: $draft.kind) {
                    ForEach(DestinationDraft.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: draft.kind) { _, _ in
                    test = .idle
                    apply()
                }
            } footer: {
                Text("A local folder also covers NAS shares mounted in Finder (SMB/NFS/WebDAV). SFTP reaches any SSH server — like a Navidrome host.")
                    .settingsFooter()
            }

            switch draft.kind {
            case .none:
                EmptyView()
            case .folder:
                Section("Folder") {
                    HStack {
                        TextField("Path", text: $draft.folderPath, prompt: Text("/Volumes/Music"))
                            .onSubmit(apply)
                        Button("Choose…", action: chooseFolder)
                    }
                }
            case .sftp:
                sftpSections
            }

            if draft.kind != .none {
                Section {
                    HStack {
                        Button(action: runTest) {
                            if case .running = test {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Test Connection")
                            }
                        }
                        .disabled({ if case .running = test { true } else { false } }())
                        if case .finished(let message, let failed) = test {
                            Label(message, systemImage: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(failed ? .red : .green)
                                .font(.callout)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(loadOnce)
    }

    @ViewBuilder private var sftpSections: some View {
        Section("Server") {
            TextField("Host", text: $draft.host, prompt: Text("navidrome.example.com"))
                .onSubmit(apply)
            TextField("Port", value: $draft.port, format: .number.grouping(.never))
                .onSubmit(apply)
            TextField("User", text: $draft.username)
                .onSubmit(apply)
            TextField("Music folder on the server", text: $draft.remotePath, prompt: Text("/srv/music"))
                .onSubmit(apply)
        }
        Section("Authentication") {
            Picker("Method", selection: $draft.usesKeyFile) {
                Text("Password").tag(false)
                Text("SSH key file").tag(true)
            }
            .onChange(of: draft.usesKeyFile) { _, _ in apply() }
            if draft.usesKeyFile {
                HStack {
                    TextField("Private key", text: $draft.keyFile, prompt: Text("~/.ssh/id_ed25519"))
                        .onSubmit(apply)
                    Button("Choose…", action: chooseKeyFile)
                }
                SecureField("Key passphrase (if any)", text: $password)
                    .onSubmit(apply)
            } else {
                SecureField("Password", text: $password)
                    .onSubmit(apply)
            }
            Text("The secret is stored in your Keychain, never in preference files.")
                .settingsFooter()
        }
        Section {
            Button("Forget Saved Host Key", role: .destructive, action: forgetHostKey)
                .disabled(draft.host.isEmpty)
            Text("Spindle pins this server's SSH key the first time it connects and refuses to upload if the key later changes. Forget it only when you know the server's key changed for a legitimate reason — the next key you see will be trusted.")
                .settingsFooter()
        }
    }

    // MARK: Loading and applying

    /// Runs once per pane instance: re-reading on every tab switch would
    /// discard unsaved edits and hit the Keychain again.
    @Sendable private func loadOnce() async {
        guard !loaded else { return }
        loaded = true
        draft = DestinationDraft(model.preferences.destination)
        guard let account = draft.keychainAccount else { return }
        // SecItemCopyMatching blocks the calling thread until any Keychain
        // access dialog is answered — never on the main thread.
        password = await Task.detached(priority: .utility) {
            KeychainStore.load(account: account) ?? ""
        }.value
    }

    /// Persists the draft when it describes a complete destination, and the
    /// secret when one was typed. Writes only on real change.
    private func apply() {
        let config = draft.config
        if config != model.preferences.destination {
            model.preferences.destination = config
        }
        if let account = draft.keychainAccount, !password.isEmpty {
            let secret = password
            Task.detached(priority: .utility) {
                try? KeychainStore.save(secret: secret, account: account)
            }
        }
    }

    private func chooseFolder() {
        guard let url = FilePicker.chooseFolder(prompt: "Use This Folder") else { return }
        draft.folderPath = url.path
        apply()
    }

    private func chooseKeyFile() {
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        guard let url = FilePicker.chooseFile(in: ssh, showsHiddenFiles: true) else { return }
        draft.keyFile = url.path
        apply()
    }

    private func forgetHostKey() {
        let host = draft.host
        let port = draft.port
        guard !host.isEmpty else { return }
        Task.detached(priority: .utility) {
            KeychainHostKeyStore().removePin(host: host, port: port)
        }
        test = .finished(message: "Forgot the saved host key for \(host). The next connection will trust a new key.", failed: false)
    }

    private func runTest() {
        apply()
        guard let config = draft.config else { return }
        test = .running
        let secret = password.isEmpty ? nil : password
        Task {
            let destination: any Destination = switch config {
            case .localFolder(let path): LocalFolderDestination(path: path)
            case .sftp(let sftpConfig): SFTPDestination(config: sftpConfig, secret: secret)
            }
            let result = await destination.test()
            await destination.close()
            switch result {
            case .success(let message): test = .finished(message: message, failed: false)
            case .failure(let error): test = .finished(message: String(describing: error), failed: true)
            }
        }
    }
}
