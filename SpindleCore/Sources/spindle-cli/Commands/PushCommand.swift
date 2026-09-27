import Foundation
import Transfer

enum PushCommand {
    static let help = """
      push <dir> [options]
                        upload a directory tree to a destination
        --to <dest>     folder path, or sftp://user@host[:port]/remote/path
        --key <file>    SSH private key (default: password via
                        SPINDLE_SFTP_PASSWORD or saved Keychain entry)
        --save-password store the password in the Keychain for later runs
    """

    static func run(_ args: ArraySlice<String>) async throws {
        var scanner = ArgumentScanner(args)
        var sourceDir: String?
        var destSpec: String?
        var keyFile: String?
        var savePassword = false

        while let argument = scanner.next() {
            switch argument {
            case "--to": destSpec = scanner.value(after: "--to")
            case "--key": keyFile = scanner.value(after: "--key")
            case "--save-password": savePassword = true
            default: sourceDir = scanner.positional(argument, replacing: sourceDir)
            }
        }

        guard let sourceDir, let destSpec else { fail("push needs <dir> and --to <dest>") }
        guard let config = DestinationConfig.parse(destSpec) else {
            fail("SFTP destination must look like sftp://user@host[:port]/remote/path")
        }

        let destination: any Destination
        switch config {
        case .localFolder(let path):
            destination = LocalFolderDestination(path: path)
        case .sftp(var sftp):
            var secret = ProcessInfo.processInfo.environment["SPINDLE_SFTP_PASSWORD"]
                ?? KeychainStore.load(account: sftp.keychainAccount)
            if let keyFile {
                sftp.authentication = .privateKeyFile(path: keyFile)
            } else if secret == nil {
                print("Password for \(sftp.keychainAccount): ", terminator: "")
                secret = readLine(strippingNewline: true)
            }
            if savePassword, let secret, case .password = sftp.authentication {
                try KeychainStore.save(secret: secret, account: sftp.keychainAccount)
                print("Password saved to Keychain.")
            }
            destination = SFTPDestination(config: sftp, secret: secret)
        }

        switch await destination.test() {
        case .success(let message): print(message)
        case .failure(let error): fail("Destination test failed: \(error)")
        }

        let files = regularFiles(under: URL(fileURLWithPath: sourceDir))
        guard !files.isEmpty else { fail("Nothing to upload in \(sourceDir)") }

        print("Uploading \(files.count) files…")
        let pushStarted = Date()
        for (url, relative) in files {
            try await destination.upload(file: url, toRelativePath: relative, progress: nil)
            print("  \(relative)")
        }
        await destination.close()
        print(String(format: "Uploaded in %.1fs.", -pushStarted.timeIntervalSinceNow))
    }

    /// Every non-hidden regular file under `root` with its root-relative
    /// path, sorted. Symlinks are resolved so `/tmp` → `/private/tmp` can't
    /// break the relative-path math.
    private static func regularFiles(under root: URL) -> [(URL, String)] {
        let resolvedRoot = root.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        var files: [(URL, String)] = []
        while let item = enumerator?.nextObject() as? URL {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  !item.lastPathComponent.hasPrefix(".")
            else { continue }
            let itemPath = item.resolvingSymlinksInPath().path
            guard itemPath.hasPrefix(resolvedRoot + "/") else { continue }
            files.append((item, String(itemPath.dropFirst(resolvedRoot.count + 1))))
        }
        return files.sorted { $0.1 < $1.1 }
    }
}
