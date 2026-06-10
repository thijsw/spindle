import Foundation

/// Delivers files into a local folder — which covers SMB/NFS/WebDAV NAS
/// shares mounted in Finder as well.
public struct LocalFolderDestination: Destination {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public init(path: String) {
        self.root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    public func prepare() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: root.path) else {
            throw DestinationError.notWritable(root.path)
        }
    }

    public func upload(
        file: URL,
        toRelativePath relativePath: String,
        progress: (@Sendable (TransferProgress) -> Void)?
    ) async throws {
        let destination = root.appendingPathComponent(relativePath)
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let partial = directory.appendingPathComponent(".\(destination.lastPathComponent).part")
        try? FileManager.default.removeItem(at: partial)
        do {
            try FileManager.default.copyItem(at: file, to: partial)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw DestinationError.uploadFailed(path: relativePath, reason: String(describing: error))
        }

        if let size = try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64 {
            progress?(TransferProgress(bytesSent: size, totalBytes: size))
        }
    }

    public func test() async -> Result<String, Error> {
        do {
            try await prepare()
            let probe = root.appendingPathComponent(".spindle-write-test")
            try Data("ok".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
            return .success("Folder is writable.")
        } catch {
            return .failure(error)
        }
    }

    public func close() async {}
}
