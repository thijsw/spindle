import Encoding
import Foundation
import Metadata
import Naming

/// The files one album delivers, with their library-relative paths: the
/// audio tracks, and per album folder the optional cover, rip log and cue
/// sheet (a multi-disc template can spread one album over several folders).
/// Pure planning — nothing is rendered or written here — so the layout can
/// be tested without an encoder.
struct DeliveryPlan: Equatable {
    enum Content: Equatable {
        case audio(trackNumber: Int)
        case cover
        case ripLog
        /// Cue sheet for the tracks whose files live in the same folder
        /// (track position → file name).
        case cueSheet(fileNames: [Int: String])
    }

    struct File: Equatable {
        let relativePath: String
        let content: Content
    }

    let files: [File]

    /// - Parameters:
    ///   - rippedTrackNumbers: disc track numbers that produced audio; a
    ///     track abandoned by the rip is simply absent. Ripped tracks map to
    ///     album positions by disc track number (single-session discs,
    ///     ripped in order).
    ///   - coverExtension: file extension of the cover to write into each
    ///     folder, or nil for no cover file.
    static func build(
        album: ResolvedAlbum,
        rippedTrackNumbers: [Int],
        template: NamingTemplate,
        format: AudioFormat,
        coverExtension: String?,
        ripLog: Bool,
        cueSheet: Bool
    ) -> DeliveryPlan {
        var files: [File] = []
        var folderOrder: [String] = []
        var folderFiles: [String: [Int: String]] = [:]

        for number in rippedTrackNumbers {
            guard let track = album.tracks.first(where: { $0.position == number }) else { continue }
            let relative = template.render(album: album, track: track) + "." + format.fileExtension
            files.append(File(relativePath: relative, content: .audio(trackNumber: number)))
            let path = relative as NSString
            let folder = path.deletingLastPathComponent
            if folderFiles[folder] == nil { folderOrder.append(folder) }
            folderFiles[folder, default: [:]][track.position] = path.lastPathComponent
        }

        // Archival artifacts, named "<Artist> - <Album>" like EAC's.
        let baseName = PathSanitizer.component("\(album.albumArtist) - \(album.album)")
        for folder in folderOrder {
            func inFolder(_ name: String) -> String { folder.isEmpty ? name : "\(folder)/\(name)" }
            if let coverExtension {
                files.append(File(relativePath: inFolder("cover.\(coverExtension)"), content: .cover))
            }
            if ripLog {
                files.append(File(relativePath: inFolder("\(baseName).log"), content: .ripLog))
            }
            if cueSheet {
                files.append(File(
                    relativePath: inFolder("\(baseName).cue"),
                    content: .cueSheet(fileNames: folderFiles[folder] ?? [:])
                ))
            }
        }
        return DeliveryPlan(files: files)
    }
}
