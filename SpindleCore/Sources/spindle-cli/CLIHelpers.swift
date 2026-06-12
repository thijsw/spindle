import DiscDrive
import Foundation
import Metadata
import RipEngine

// Shared plumbing for the subcommands in main.swift.

let cliUserAgent = "Spindle/0.1 ( thijs@wijnmaalen.name )"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func resolveDisc(_ argument: String?) -> String {
    if let argument { return argument }
    guard let first = DiscEnumerator.presentCDMedia().first else {
        fail("No CD medium present. Insert a disc or pass a BSD name.")
    }
    return first
}

func loadTOC(bsdName: String) async throws -> TOC {
    let drive = try CDDrive(bsdName: bsdName)
    let raw = try await drive.readFullTOC()
    return try TOC.parse(fullTOC: raw)
}

/// Walks a subcommand's argument list, replacing the hand-rolled index
/// loops: `value(after:)` consumes the next argument as an option's value,
/// `positional(_:replacing:)` accepts at most one bare argument.
struct ArgumentScanner {
    private let args: [String]
    private var index = 0

    init(_ args: some Sequence<String>) {
        self.args = Array(args)
    }

    mutating func next() -> String? {
        guard index < args.count else { return nil }
        defer { index += 1 }
        return args[index]
    }

    mutating func value(after option: String) -> String {
        guard let value = next() else { fail("\(option) needs a value") }
        return value
    }

    mutating func intValue(after option: String) -> Int {
        guard let n = Int(value(after: option)) else { fail("\(option) needs a number") }
        return n
    }

    func positional(_ argument: String, replacing current: String?) -> String {
        guard current == nil, !argument.hasPrefix("--") else {
            fail("Unknown option: \(argument)")
        }
        return argument
    }
}

/// Parses a MusicBrainz-style "first last leadout offsets…" TOC string.
func parseDiscTOC(_ tocString: String) -> DiscTOC {
    let numbers = tocString.split(separator: " ").compactMap { Int($0) }
    guard numbers.count >= 4 else { fail("TOC string needs: first last leadout offsets…") }
    let toc = DiscTOC(
        firstTrack: numbers[0],
        lastTrack: numbers[1],
        leadOutOffset: numbers[2],
        trackOffsets: Array(numbers.dropFirst(3))
    )
    guard toc.trackOffsets.count == toc.lastTrack - toc.firstTrack + 1 else {
        fail("TOC string has \(toc.trackOffsets.count) offsets for tracks \(toc.firstTrack)–\(toc.lastTrack)")
    }
    return toc
}

/// WAV files in `directory`, sorted by filename. The default prefix matches
/// the staging layout's trackNN.wav names.
func wavFiles(in directory: String, prefix: String = "track") -> [URL] {
    let urls = (try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil
    )) ?? []
    return urls
        .filter { $0.pathExtension == "wav" && $0.lastPathComponent.hasPrefix(prefix) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// Serializes one-line progress output from the rip callback.
final class ProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastLine = ""

    func print(_ progress: RipProgress) {
        lock.lock()
        defer { lock.unlock() }
        let line = String(
            format: "\rtrack %02d  %3d%%%@",
            progress.trackNumber,
            Int(progress.fraction * 100),
            progress.rereads > 0 ? "  (\(progress.rereads) re-reads)" : ""
        )
        guard line != lastLine else { return }
        lastLine = line
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}

func formatMSF(_ sectors: Int) -> String {
    let s = sectors + 150
    return String(format: "%02d:%02d.%02d", s / (60 * 75), (s / 75) % 60, s % 75)
}

extension Duration {
    /// Whole duration in seconds, for rate math.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
