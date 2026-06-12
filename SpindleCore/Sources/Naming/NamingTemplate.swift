import Foundation
import Metadata

/// Renders library-relative paths from a template.
///
/// Syntax:
/// - `{token}` is replaced by its value (see `tokens`); `{track}` is
///   zero-padded to two digits.
/// - `[ ... ]` groups are dropped entirely when any token inside is empty,
///   e.g. `[ ({year})]` or `[{disc}-]`.
/// - `/` separates path components; each component is sanitized after
///   rendering.
///
/// Default: `{albumartist}/{album}[ ({year})]/[{disc}-]{track} - {title}`
public struct NamingTemplate: Sendable, Equatable, Codable {
    public var template: String

    public static let standard = NamingTemplate(
        template: "{albumartist}/{album}[ ({year})]/[{disc}-]{track} - {title}"
    )

    public static let discFolders = NamingTemplate(
        template: "{albumartist}/{album}[ ({year})][/Disc {disc}]/{track} - {title}"
    )

    public init(template: String) {
        self.template = template
    }

    /// Renders the relative path (without file extension) for one track.
    public func render(album: ResolvedAlbum, track: ResolvedTrack) -> String {
        let values = Self.tokenValues(album: album, track: track)
        var output = ""
        var groupStack: [(content: String, dropped: Bool)] = []

        var index = template.startIndex
        func append(_ s: String) {
            if groupStack.isEmpty { output += s } else { groupStack[groupStack.count - 1].content += s }
        }

        while index < template.endIndex {
            let char = template[index]
            switch char {
            case "[":
                groupStack.append(("", false))
            case "]":
                if let group = groupStack.popLast(), !group.dropped {
                    append(group.content)
                }
            case "{":
                guard let close = template[index...].firstIndex(of: "}") else {
                    append(String(char))
                    break
                }
                let token = String(template[template.index(after: index) ..< close])
                // Tag values must never introduce path separators; only the
                // template itself creates directories.
                let value = (values[token] ?? "").replacingOccurrences(of: "/", with: "-")
                if value.isEmpty, !groupStack.isEmpty {
                    groupStack[groupStack.count - 1].dropped = true
                }
                append(value)
                index = close
            default:
                append(String(char))
            }
            index = template.index(after: index)
        }

        let components = output
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { PathSanitizer.component(String($0)) }
            .filter { !$0.isEmpty }
        return components.joined(separator: "/")
    }

    private static func tokenValues(album: ResolvedAlbum, track: ResolvedTrack) -> [String: String] {
        [
            "albumartist": album.albumArtist,
            "album": album.album,
            "artist": track.artist,
            "title": track.title,
            "year": album.year ?? "",
            "originalyear": album.originalDate.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil } ?? "",
            "date": album.date ?? "",
            "track": String(format: "%02d", track.position),
            "disc": album.discTotal > 1 ? String(album.discNumber) : "",
            "disctotal": album.discTotal > 1 ? String(album.discTotal) : "",
        ]
    }
}

/// Sanitizes a single path component so it is safe for the local file system
/// and for SMB/Windows-compatible NAS volumes (the strict superset we always
/// target, so a folder can be moved between APFS, SMB, and SFTP unchanged).
public enum PathSanitizer {
    private static let windowsReserved: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for n in 1...9 {
            names.insert("COM\(n)")
            names.insert("LPT\(n)")
        }
        return names
    }()

    public static func component(_ input: String) -> String {
        // NFC: SFTP servers and Linux hosts expect precomposed names.
        var s = input.precomposedStringWithCanonicalMapping

        s = String(s.map { char in
            if char == "/" || char == ":" { return "-" }
            if char.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) { return " " }
            if "\\<>\"|?*".contains(char) { return "-" }
            return char
        })

        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        while s.hasSuffix(".") || s.hasSuffix(" ") { s.removeLast() }

        if windowsReserved.contains(s.uppercased()) {
            s += "_"
        }

        // Cap at 240 bytes of UTF-8 without splitting characters.
        while s.utf8.count > 240 {
            s.removeLast()
        }
        return s
    }
}
