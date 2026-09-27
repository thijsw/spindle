import Encoding
import Foundation
import Metadata
import SpindleCore

enum EncodeCommand {
    static let help = """
      encode <wavdir> [options]
                        encode staged track WAVs (track01.wav…) with the app's
                        naming template, format and cover settings
        --out <dir>     library root (default: ./library)
        --format <f>    flac, alac, or aac (default: the format from Settings)
        --toc "<str>"   MusicBrainz TOC string for metadata lookup
        --pick <n>      candidate to use when several match (default: best)
    """

    static func run(_ args: ArraySlice<String>) async throws {
        var scanner = ArgumentScanner(args)
        var wavDir: String?
        var outDir = URL(fileURLWithPath: "library")
        var preferences = PreferencesStore.load()
        var tocString: String?
        var pick: Int?

        while let argument = scanner.next() {
            switch argument {
            case "--out":
                outDir = URL(fileURLWithPath: scanner.value(after: "--out"))
            case "--format":
                guard let chosen = AudioFormat(rawValue: scanner.value(after: "--format")) else {
                    fail("--format must be flac, alac, or aac")
                }
                preferences.format = chosen
            case "--toc":
                tocString = scanner.value(after: "--toc")
            case "--pick":
                pick = scanner.intValue(after: "--pick")
            default:
                wavDir = scanner.positional(argument, replacing: wavDir)
            }
        }

        guard let wavDir else { fail("encode needs a directory of trackNN.wav files") }
        let wavURLs = wavFiles(in: wavDir)
        guard !wavURLs.isEmpty else { fail("No trackNN.wav files in \(wavDir)") }

        var album = ResolvedAlbum.fallback(cdText: nil, discID: nil, trackCount: wavURLs.count)
        var art: CoverArt?
        if let tocString {
            let discTOC = parseDiscTOC(tocString)
            let lookup = try await ReleaseLookup.perform(
                disc: discTOC,
                audioTrackCount: wavURLs.count,
                metadata: MusicBrainzClient(userAgent: Spindle.userAgent),
                preferences: preferences.metadata
            )
            let chosen: MBRelease?
            if let pick {
                guard pick >= 1, pick <= lookup.ranked.count else { fail("--pick out of range") }
                chosen = lookup.ranked[pick - 1].release
            } else {
                chosen = lookup.ranked.first?.release
            }
            if let chosen, let resolved = ResolvedAlbum(
                release: chosen, discID: discTOC.musicBrainzDiscID, audioTrackCount: wavURLs.count
            ) {
                album = resolved
                print("Tagging as: \(album.albumArtist) — \(album.album)")
                art = await fetchArt(for: album)
                if let art { print("Cover art: \(art.source.rawValue), \(art.data.count / 1024) KB") }
            } else {
                print("No MusicBrainz match; tagging as Unknown Album.")
                album = ResolvedAlbum.fallback(cdText: nil, discID: discTOC.musicBrainzDiscID, trackCount: wavURLs.count)
            }
        }

        guard album.tracks.count == wavURLs.count else {
            fail("Release has \(album.tracks.count) tracks but \(wavURLs.count) WAVs found.")
        }

        // Staged WAVs are in disc order; positions start at 1.
        let staged = Dictionary(uniqueKeysWithValues: zip(album.tracks.map(\.position), wavURLs))
        let files = try await AlbumEncoder(preferences: preferences).encode(
            AlbumEncoder.Input(album: album, wavURLs: staged, art: art), into: outDir
        )
        for file in files {
            print("  \(file.relativePath)")
        }
    }
}
