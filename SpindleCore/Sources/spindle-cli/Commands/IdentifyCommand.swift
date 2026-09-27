import DiscDrive
import Foundation
import Metadata
import SpindleCore

enum IdentifyCommand {
    static let help = """
      identify [disk] [options]
                        look up the disc on MusicBrainz
        --pick <n>      show full tags for candidate n
        --art <file>    download cover art for the picked release
        --toc "<str>"   use a TOC string ("first last leadout offsets…")
                        instead of reading a disc
    """

    static func run(_ args: ArraySlice<String>) async throws {
        var scanner = ArgumentScanner(args)
        var disk: String?
        var pick: Int?
        var artPath: String?
        var tocString: String?

        while let argument = scanner.next() {
            switch argument {
            case "--pick": pick = scanner.intValue(after: "--pick")
            case "--art": artPath = scanner.value(after: "--art")
            case "--toc": tocString = scanner.value(after: "--toc")
            default: disk = scanner.positional(argument, replacing: disk)
            }
        }

        let discTOC: DiscTOC
        let audioTrackCount: Int
        if let tocString {
            discTOC = parseDiscTOC(tocString)
            audioTrackCount = discTOC.trackOffsets.count
        } else {
            let (drive, toc) = try await openDisc(bsdName: resolveDisc(disk))
            guard let fromDisc = DiscTOC(toc: toc) else { fail("Disc has no audio tracks.") }
            discTOC = fromDisc
            audioTrackCount = toc.audioTracks.count

            if let packs = ((try? await drive.readCDTextPacks()) ?? nil),
               let cdText = CDTextParser.parse(packs: packs) {
                print("CD-TEXT: \(cdText.albumPerformer ?? "?") — \(cdText.albumTitle ?? "?")")
            }
        }

        print("DiscID \(discTOC.musicBrainzDiscID) — querying MusicBrainz…")
        let lookup = try await ReleaseLookup.perform(
            disc: discTOC,
            audioTrackCount: audioTrackCount,
            metadata: MusicBrainzClient(userAgent: Spindle.userAgent),
            preferences: PreferencesStore.load().metadata
        )
        guard !lookup.ranked.isEmpty else {
            print("No matches on MusicBrainz.")
            return
        }
        print(lookup.exactDiscID
            ? "Exact DiscID match: \(lookup.ranked.count) release(s)"
            : "DiscID unknown; fuzzy TOC match: \(lookup.ranked.count) candidate(s)")

        for (index, item) in lookup.ranked.enumerated() {
            let release = item.release
            let medium = release.bestMedium(discID: discTOC.musicBrainzDiscID, audioTrackCount: audioTrackCount)
            print(String(
                format: "%2d. %@ — %@ (%@, %@, %@, %@ tracks)%@",
                index + 1,
                (release.artistCredit ?? []).joinedName,
                release.title,
                release.date ?? "no date",
                release.country ?? "??",
                medium?.format ?? "?",
                String(medium?.effectiveTrackCount ?? 0),
                index == 0 ? String(format: "  [confidence %.0f%%]", item.confidence * 100) : ""
            ))
        }

        guard let pick else { return }
        guard pick >= 1, pick <= lookup.ranked.count else { fail("--pick out of range") }
        guard let album = ResolvedAlbum(
            release: lookup.ranked[pick - 1].release,
            discID: discTOC.musicBrainzDiscID,
            audioTrackCount: audioTrackCount
        ) else { fail("Could not resolve that release.") }

        print("\n\(album.albumArtist) — \(album.album)")
        print("\(album.date ?? "") \(album.label ?? "") \(album.catalogNumber ?? "") disc \(album.discNumber)/\(album.discTotal)")
        for track in album.tracks {
            print(String(format: "  %02d. %@ — %@", track.position, track.artist, track.title))
        }

        if let artPath {
            if let art = await fetchArt(for: album) {
                try art.data.write(to: URL(fileURLWithPath: artPath))
                print("Cover art (\(art.source.rawValue), \(art.data.count / 1024) KB) → \(artPath)")
            } else {
                print("No cover art found.")
            }
        }
    }
}
