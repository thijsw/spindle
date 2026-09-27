import DiscDrive
import Foundation
import Metadata

/// The disc-inspection commands: detect, drives, toc, discid.
enum DiscCommands {
    static func detect() async throws {
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
    }

    static func drives() {
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
    }

    static func toc(_ args: ArraySlice<String>) async throws {
        let bsd = resolveDisc(args.first)
        let (_, toc) = try await openDisc(bsdName: bsd)
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
    }

    static func discid(_ args: ArraySlice<String>) async throws {
        let bsd = resolveDisc(args.first)
        let (_, toc) = try await openDisc(bsdName: bsd)
        guard let discTOC = DiscTOC(toc: toc) else {
            fail("Disc has no audio tracks.")
        }
        print("MusicBrainz DiscID: \(discTOC.musicBrainzDiscID)")
        print("FreeDB ID:          \(discTOC.freeDBDiscID)")
        print("TOC string:         \(discTOC.musicBrainzTOCString)")
        print("Lookup URL:         https://musicbrainz.org/ws/2/discid/\(discTOC.musicBrainzDiscID)?fmt=json")
    }
}
