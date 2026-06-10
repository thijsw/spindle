import DiscDrive
import Foundation
import Metadata

// Debug/development CLI. Each milestone adds a subcommand so every subsystem
// can be exercised headless before the app UI exists.

let usage = """
usage: spindle-cli <command>

commands:
  detect            watch for disc insertions/removals (Ctrl-C to stop)
  drives            list present CD media and drive identity
  toc [disk]        read and print the table of contents
  discid [disk]     compute the MusicBrainz DiscID and TOC string

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

default:
    print(usage)
    exit(64)
}
