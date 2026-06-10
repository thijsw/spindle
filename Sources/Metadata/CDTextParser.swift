import DiscRecording
import Foundation

/// Album/track strings read from a disc's CD-TEXT, when present.
public struct CDTextInfo: Sendable, Hashable, Codable {
    public var albumTitle: String?
    public var albumPerformer: String?
    /// Keyed by track number (1-based).
    public var trackTitles: [Int: String]
    public var trackPerformers: [Int: String]

    public init(
        albumTitle: String? = nil,
        albumPerformer: String? = nil,
        trackTitles: [Int: String] = [:],
        trackPerformers: [Int: String] = [:]
    ) {
        self.albumTitle = albumTitle
        self.albumPerformer = albumPerformer
        self.trackTitles = trackTitles
        self.trackPerformers = trackPerformers
    }

    public var isEmpty: Bool {
        albumTitle == nil && albumPerformer == nil && trackTitles.isEmpty
    }
}

/// Parses raw CD-TEXT packs (DKIOCCDREADTOC format 5) using DiscRecording's
/// DRCDTextBlock — the documented pairing for that ioctl.
public enum CDTextParser {
    public static func parse(packs: Data) -> CDTextInfo? {
        // The ioctl response has a 4-byte header before the 18-byte packs;
        // DRCDTextBlock wants just the packs. Try stripped first, then raw.
        for candidate in [packs.dropFirst(4), packs[...]] {
            if let info = parseBlocks(Data(candidate)), !info.isEmpty {
                return info
            }
        }
        return nil
    }

    private static func parseBlocks(_ packs: Data) -> CDTextInfo? {
        guard packs.count >= 18, packs.count % 18 == 0 else { return nil }
        guard let blocks = DRCDTextBlock.arrayOfCDTextBlocks(fromPacks: packs) as? [DRCDTextBlock],
              let block = blocks.first
        else { return nil }

        guard let dictionaries = block.trackDictionaries() as? [[String: Any]],
              !dictionaries.isEmpty
        else { return nil }

        var info = CDTextInfo()
        for (index, dict) in dictionaries.enumerated() {
            let title = (dict[DRCDTextTitleKey] as? String)?.trimmingCharacters(in: .whitespaces)
            let performer = (dict[DRCDTextPerformerKey] as? String)?.trimmingCharacters(in: .whitespaces)
            if index == 0 {
                // Index 0 describes the album.
                info.albumTitle = title?.isEmpty == false ? title : nil
                info.albumPerformer = performer?.isEmpty == false ? performer : nil
            } else {
                if let title, !title.isEmpty { info.trackTitles[index] = title }
                if let performer, !performer.isEmpty { info.trackPerformers[index] = performer }
            }
        }
        return info
    }
}
