import Foundation
import Testing
import Transfer

@Suite struct LocalFolderDestinationTests {
    @Test func uploadRenameOverwriteAndTest() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("library")
        let source = base.appendingPathComponent("song.flac")
        let payload = Data((0 ..< 100_000).map { UInt8($0 % 251) })
        try payload.write(to: source)

        let destination = LocalFolderDestination(root: root)
        try await destination.prepare()
        #expect(FileManager.default.fileExists(atPath: root.path), "prepare creates the root")

        try await destination.upload(
            file: source,
            toRelativePath: "Artist/Album (1999)/01 - Song.flac",
            progress: nil
        )
        let final = root.appendingPathComponent("Artist/Album (1999)/01 - Song.flac")
        #expect(try Data(contentsOf: final) == payload, "upload lands byte-identical at the nested path")

        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: final.deletingLastPathComponent().path)
            .filter { $0.hasSuffix(".part") }
        #expect(leftovers.isEmpty, "no .part files left behind")

        // Overwrite must replace, not fail.
        let updated = Data("replacement".utf8)
        try updated.write(to: source)
        try await destination.upload(
            file: source,
            toRelativePath: "Artist/Album (1999)/01 - Song.flac",
            progress: nil
        )
        #expect(try Data(contentsOf: final) == updated, "re-upload replaces the file")

        let result = await destination.test()
        #expect(throws: Never.self) { try result.get() }
    }

    @Test func unwritableDestinationFailsTest() async {
        let blocked = LocalFolderDestination(path: "/System/spindle-cannot-write-here")
        let result = await blocked.test()
        #expect(throws: (any Error).self) { try result.get() }
    }
}

@Suite struct DestinationConfigTests {
    @Test func displayNameAndKeychainAccount() throws {
        let sftp = DestinationConfig.sftp(SFTPConfig(
            host: "navidrome.local",
            username: "music",
            remotePath: "/srv/music"
        ))
        #expect(sftp.displayName == "SFTP: music@navidrome.local/srv/music")
        if case .sftp(let config) = sftp {
            #expect(config.keychainAccount == "music@navidrome.local:22")
        }

        let data = try JSONEncoder().encode(sftp)
        let decoded = try JSONDecoder().decode(DestinationConfig.self, from: data)
        #expect(decoded == sftp, "config round-trips through JSON")
    }
}
