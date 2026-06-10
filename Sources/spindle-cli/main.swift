import DiscDrive
import Foundation
import Metadata
import RipEngine

// Debug/development CLI. Each milestone adds a subcommand so every subsystem
// can be exercised headless before the app UI exists.

let usage = """
usage: spindle-cli <command>

commands:
  detect            watch for disc insertions/removals (Ctrl-C to stop)
  drives            list present CD media and drive identity
  toc [disk]        read and print the table of contents
  discid [disk]     compute the MusicBrainz DiscID and TOC string
  rip [disk] [options]
                    rip audio tracks to WAV files
    --out <dir>     output directory (default: ./rip)
    --fast          burst mode (default: secure)
    --offset <n>    sample offset correction (default: 0)
    --track <n>     rip a single track

[disk] is a BSD name like disk4; defaults to the first CD medium found.
"""

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

let arguments = CommandLine.arguments.dropFirst()
guard let command = arguments.first else {
    print(usage)
    exit(0)
}

switch command {
case "detect":
    let monitor = try DriveMonitor()
    print("Watching for CD media (Ctrl-C to stop)…")
    for bsd in DiscEnumerator.presentCDMedia() {
        print("already present: \(bsd)")
    }
    for await event in monitor.events {
        switch event {
        case .discAppeared(let bsd): print("appeared:    \(bsd)")
        case .discDisappeared(let bsd): print("disappeared: \(bsd)")
        }
    }

case "drives":
    let media = DiscEnumerator.presentCDMedia()
    if media.isEmpty { print("No CD media present.") }
    for bsd in media {
        if let identity = DiscEnumerator.driveIdentity(forMediaBSDName: bsd) {
            var line = "\(bsd): \(identity.displayName) [\(identity.revision)]"
            if let suggestion = DriveOffsetTable.suggestion(for: identity) {
                line += " — suggested read offset: \(suggestion.samples) samples (unverified)"
            }
            print(line)
        } else {
            print("\(bsd): unknown drive")
        }
    }

case "toc":
    let bsd = resolveDisc(arguments.dropFirst().first)
    let toc = try await loadTOC(bsdName: bsd)
    print("Disc in \(bsd): sessions \(toc.firstSession)–\(toc.lastSession), \(toc.tracks.count) tracks")
    for track in toc.tracks {
        let length = toc.lengthInSectors(of: track)
        let seconds = Double(length) / 75.0
        print(String(
            format: "  %2d  %@  start %6d  length %6d (%d:%04.1f)  %@%@",
            track.number,
            track.isAudio ? "audio" : "data ",
            track.startLBA,
            length,
            Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60),
            "session \(track.session)",
            track.hasPreEmphasis ? ", pre-emphasis" : ""
        ))
    }
    print("  lead-out at \(toc.leadOutLBA) (\(formatMSF(toc.leadOutLBA)))")

case "discid":
    let bsd = resolveDisc(arguments.dropFirst().first)
    let toc = try await loadTOC(bsdName: bsd)
    guard let discTOC = DiscTOC(toc: toc) else {
        fail("Disc has no audio tracks.")
    }
    print("MusicBrainz DiscID: \(discTOC.musicBrainzDiscID)")
    print("FreeDB ID:          \(discTOC.freeDBDiscID)")
    print("TOC string:         \(discTOC.musicBrainzTOCString)")
    print("Lookup URL:         https://musicbrainz.org/ws/2/discid/\(discTOC.musicBrainzDiscID)?fmt=json")

case "rip":
    var rest = Array(arguments.dropFirst())
    var outDir = URL(fileURLWithPath: "rip")
    var mode = RipConfiguration.Mode.secureDefault
    var offset = 0
    var onlyTrack: Int?
    var disk: String?

    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--out":
            i += 1
            guard i < rest.count else { fail("--out needs a value") }
            outDir = URL(fileURLWithPath: rest[i])
        case "--fast":
            mode = .burst
        case "--offset":
            i += 1
            guard i < rest.count, let n = Int(rest[i]) else { fail("--offset needs a number") }
            offset = n
        case "--track":
            i += 1
            guard i < rest.count, let n = Int(rest[i]) else { fail("--track needs a number") }
            onlyTrack = n
        default:
            if disk == nil, !rest[i].hasPrefix("--") {
                disk = rest[i]
            } else {
                fail("Unknown option: \(rest[i])")
            }
        }
        i += 1
    }

    let bsd = resolveDisc(disk)

    // Unmount the cddafs volume so raw reads don't race the filesystem,
    // and keep it from re-mounting mid-rip.
    let monitor = try DriveMonitor()
    try? await monitor.hold(bsdName: bsd)
    defer { monitor.release(bsdName: bsd) }

    let drive = try CDDrive(bsdName: bsd)
    var toc = try TOC.parse(fullTOC: try await drive.readFullTOC())
    if let onlyTrack {
        guard toc.tracks.contains(where: { $0.number == onlyTrack && $0.isAudio }) else {
            fail("No audio track \(onlyTrack) on this disc.")
        }
        toc = TOC(
            tracks: toc.tracks.filter { $0.number == onlyTrack },
            sessionLeadOuts: toc.sessionLeadOuts,
            firstSession: toc.firstSession,
            lastSession: toc.lastSession
        )
    }

    if offset == 0,
       let identity = DiscEnumerator.driveIdentity(forMediaBSDName: bsd),
       let suggestion = DriveOffsetTable.suggestion(for: identity) {
        print("note: no --offset given; \(identity.displayName) drives typically need \(suggestion.samples). Ripping with 0.")
    }

    let config = RipConfiguration(mode: mode, sampleOffset: offset)
    let ripper = DiscRipper(device: drive, config: config)
    let started = Date()
    print("Ripping \(toc.audioTracks.count) tracks to \(outDir.path) (\(mode == .burst ? "burst" : "secure"))…")

    let printer = ProgressPrinter()
    let tracks = try await ripper.rip(toc: toc, to: outDir) { progress in
        printer.print(progress)
    }
    print("")
    for track in tracks {
        var line = String(
            format: "track %02d  crc32 %08X  ARv1 %08X  ARv2 %08X",
            track.trackNumber,
            track.checksums.crc32,
            track.checksums.accurateRipV1,
            track.checksums.accurateRipV2
        )
        if track.rereads > 0 { line += "  (\(track.rereads) re-reads)" }
        if !track.unrecoverableSectors.isEmpty {
            line += "  ⚠︎ \(track.unrecoverableSectors.count) unrecoverable sectors"
        }
        print(line)
    }
    print(String(format: "Done in %.1fs.", -started.timeIntervalSinceNow))

default:
    print(usage)
    exit(64)
}
