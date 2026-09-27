import DiscDrive
import Encoding
import Foundation
import Metadata

/// A file produced for delivery.
public struct DeliveredFile: Sendable {
    public let url: URL
    /// Path relative to the library root.
    public let relativePath: String
    /// Disc track number for audio files; nil for cover, log and cue.
    public let trackNumber: Int?
}

/// The encode stage: turns staged WAVs into the tagged, laid-out album files
/// (tracks, cover, rip log, cue sheet) that get delivered. Shared by the
/// pipeline and the CLI so both produce identical libraries from the same
/// preferences.
public struct AlbumEncoder: Sendable {
    public struct Input: Sendable {
        public var album: ResolvedAlbum
        /// Staged WAV per disc track number. Tracks map to album positions by
        /// disc track number (single-session discs, ripped in order).
        public var wavURLs: [Int: URL]
        public var art: CoverArt?
        /// Needed for the cue sheet (pre-emphasis flags); nil skips it.
        public var toc: TOC?
        public var discTOC: DiscTOC?
        /// Rip provenance for the archival log; nil skips it.
        public var ripLog: RipLog?

        public init(
            album: ResolvedAlbum,
            wavURLs: [Int: URL],
            art: CoverArt? = nil,
            toc: TOC? = nil,
            discTOC: DiscTOC? = nil,
            ripLog: RipLog? = nil
        ) {
            self.album = album
            self.wavURLs = wavURLs
            self.art = art
            self.toc = toc
            self.discTOC = discTOC
            self.ripLog = ripLog
        }
    }

    private let preferences: Preferences

    public init(preferences: Preferences) {
        self.preferences = preferences
    }

    /// Writes every file of the album's `DeliveryPlan` under `directory`.
    /// `onTrackEncoded` fires after each audio file, with its track number.
    public func encode(
        _ input: Input,
        into directory: URL,
        onTrackEncoded: @Sendable (Int) async -> Void = { _ in }
    ) async throws -> [DeliveredFile] {
        let plan = DeliveryPlan.build(
            album: input.album,
            rippedTrackNumbers: input.wavURLs.keys.sorted(),
            template: preferences.namingTemplate,
            format: preferences.format,
            coverExtension: preferences.writeCoverJPEG ? input.art?.fileExtension : nil,
            ripLog: preferences.writeRipLog && input.ripLog != nil,
            cueSheet: preferences.writeCueSheet && input.toc != nil
        )
        let encoder = preferences.format.makeEncoder()
        // Rendered once; every album folder gets the same log.
        let renderedLog = input.ripLog?.render()

        var delivered: [DeliveredFile] = []
        for file in plan.files {
            let url = directory.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            var trackNumber: Int?
            switch file.content {
            case .audio(let number):
                guard let wav = input.wavURLs[number],
                      let track = input.album.tracks.first(where: { $0.position == number })
                else { continue }
                try await encoder.encode(
                    wav: wav, to: url, tags: TrackTags(album: input.album, track: track), art: input.art
                )
                await onTrackEncoded(number)
                trackNumber = number
            case .cover:
                guard let art = input.art else { continue }
                try art.data.write(to: url)
            case .ripLog:
                guard let renderedLog else { continue }
                try renderedLog.write(to: url, atomically: true, encoding: .utf8)
            case .cueSheet(let fileNames):
                guard let toc = input.toc else { continue }
                let cue = CueSheet.render(
                    album: input.album, toc: toc, discTOC: input.discTOC, fileNames: fileNames,
                    comment: "Spindle \(Spindle.version)"
                )
                try cue.write(to: url, atomically: true, encoding: .utf8)
            }
            delivered.append(DeliveredFile(url: url, relativePath: file.relativePath, trackNumber: trackNumber))
        }
        return delivered
    }
}
