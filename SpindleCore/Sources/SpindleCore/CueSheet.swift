import DiscDrive
import Foundation
import Metadata

/// Renders a cue sheet for an album ripped to one file per track: each track
/// gets its own FILE entry with INDEX 01 at 00:00:00. Pre-emphasis from the
/// TOC is carried as FLAGS PRE so players and burning tools can de-emphasize.
public enum CueSheet {
    public static func render(
        album: ResolvedAlbum,
        toc: TOC,
        discTOC: DiscTOC?,
        fileNames: [Int: String], // track position → file name relative to the sheet
        comment: String
    ) -> String {
        var lines: [String] = []
        lines.append("REM COMMENT \(quote(comment))")
        if let date = album.date, date.count >= 4 {
            lines.append("REM DATE \(date.prefix(4))")
        }
        if let discTOC {
            lines.append("REM DISCID \(discTOC.freeDBDiscID.uppercased())")
        }
        lines.append("PERFORMER \(quote(album.albumArtist))")
        lines.append("TITLE \(quote(album.album))")

        let preEmphasis = Set(toc.audioTracks.filter(\.hasPreEmphasis).map(\.number))
        for track in album.tracks.sorted(by: { $0.position < $1.position }) {
            guard let fileName = fileNames[track.position] else { continue }
            lines.append("FILE \(quote(fileName)) WAVE")
            lines.append(String(format: "  TRACK %02d AUDIO", track.position))
            lines.append("    TITLE \(quote(track.title))")
            lines.append("    PERFORMER \(quote(track.artist))")
            if let isrc = track.isrc {
                lines.append("    ISRC \(isrc)")
            }
            if preEmphasis.contains(track.position) {
                lines.append("    FLAGS PRE")
            }
            lines.append("    INDEX 01 00:00:00")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Cue syntax has no escape character; double quotes inside a value
    /// become single quotes.
    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "'") + "\""
    }
}
