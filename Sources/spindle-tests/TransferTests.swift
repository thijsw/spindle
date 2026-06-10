import Foundation
import Transfer

@MainActor
func transferTests() async {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("spindle-transfer-\(ProcessInfo.processInfo.processIdentifier)")
    defer { try? FileManager.default.removeItem(at: base) }

    await Harness.asyncSuite("LocalFolderDestination") {
        let root = base.appendingPathComponent("library")
        let source = base.appendingPathComponent("song.flac")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let payload = Data((0 ..< 100_000).map { UInt8($0 % 251) })
        try? payload.write(to: source)

        let destination = LocalFolderDestination(root: root)

        do {
            try await destination.prepare()
            Harness.expect(FileManager.default.fileExists(atPath: root.path), "prepare creates the root")
        } catch {
            Harness.expect(false, "prepare threw: \(error)")
        }

        do {
            try await destination.upload(
                file: source,
                toRelativePath: "Artist/Album (1999)/01 - Song.flac",
                progress: nil
            )
            let final = root.appendingPathComponent("Artist/Album (1999)/01 - Song.flac")
            Harness.expect(
                (try? Data(contentsOf: final)) == payload,
                "upload lands byte-identical at the nested path"
            )
            let leftovers = (try? FileManager.default.contentsOfDirectory(
                atPath: final.deletingLastPathComponent().path
            ))?.filter { $0.hasSuffix(".part") } ?? []
            Harness.expect(leftovers.isEmpty, "no .part files left behind")
        } catch {
            Harness.expect(false, "upload threw: \(error)")
        }

        // Overwrite must replace, not fail.
        do {
            let updated = Data("replacement".utf8)
            try updated.write(to: source)
            try await destination.upload(
                file: source,
                toRelativePath: "Artist/Album (1999)/01 - Song.flac",
                progress: nil
            )
            let final = root.appendingPathComponent("Artist/Album (1999)/01 - Song.flac")
            Harness.expect((try? Data(contentsOf: final)) == updated, "re-upload replaces the file")
        } catch {
            Harness.expect(false, "re-upload threw: \(error)")
        }

        let result = await destination.test()
        if case .success = result {
            Harness.expect(true, "test() reports writable")
        } else {
            Harness.expect(false, "test() reports writable")
        }

        // Unwritable destination fails politely.
        let blocked = LocalFolderDestination(path: "/System/spindle-cannot-write-here")
        let blockedResult = await blocked.test()
        if case .failure = blockedResult {
            Harness.expect(true, "unwritable destination fails test()")
        } else {
            Harness.expect(false, "unwritable destination fails test()")
        }
    }

    Harness.suite("DestinationConfig") {
        let sftp = DestinationConfig.sftp(SFTPConfig(
            host: "navidrome.local",
            username: "music",
            remotePath: "/srv/music"
        ))
        Harness.expect(
            sftp.displayName == "SFTP: music@navidrome.local/srv/music",
            "SFTP display name"
        )
        if case .sftp(let config) = sftp {
            Harness.expect(config.keychainAccount == "music@navidrome.local:22", "keychain account format")
        }

        // Round-trips through Codable for preferences storage.
        if let data = try? JSONEncoder().encode(sftp),
           let decoded = try? JSONDecoder().decode(DestinationConfig.self, from: data) {
            Harness.expect(decoded == sftp, "config round-trips through JSON")
        } else {
            Harness.expect(false, "config round-trips through JSON")
        }
    }
}
