import CryptoKit
import DiscDrive
import Foundation

/// MusicBrainz disc identifiers computed from a CD's table of contents.
/// Pure-Swift reimplementation of the documented algorithm
/// (https://musicbrainz.org/doc/Disc_ID_Calculation) — libdiscid is LGPL.
public struct DiscTOC: Sendable, Hashable {
    public let firstTrack: Int
    public let lastTrack: Int
    /// Lead-out in MusicBrainz frame units (LBA + 150).
    public let leadOutOffset: Int
    /// Track start offsets in MusicBrainz frame units (LBA + 150), one per
    /// track from firstTrack through lastTrack.
    public let trackOffsets: [Int]

    public init(firstTrack: Int, lastTrack: Int, leadOutOffset: Int, trackOffsets: [Int]) {
        self.firstTrack = firstTrack
        self.lastTrack = lastTrack
        self.leadOutOffset = leadOutOffset
        self.trackOffsets = trackOffsets
    }

    /// Derives the MusicBrainz-relevant TOC from a parsed disc TOC, applying
    /// the multi-session rule: for Enhanced CDs (data track in the last
    /// session) the "lead-out" becomes the data track's start minus 11400
    /// frames, and only the audio tracks before it count.
    public init?(toc: TOC) {
        var audio = toc.audioTracks
        guard !audio.isEmpty else { return nil }

        let leadOut: Int
        if toc.lastSession > toc.firstSession,
           let dataTrack = toc.tracks.first(where: { !$0.isAudio && $0.session == toc.lastSession }) {
            leadOut = dataTrack.startLBA + 150 - 11400
            audio = audio.filter { $0.session < toc.lastSession }
            guard !audio.isEmpty else { return nil }
        } else {
            leadOut = toc.leadOutLBA + 150
        }

        self.init(
            firstTrack: audio.first!.number,
            lastTrack: audio.last!.number,
            leadOutOffset: leadOut,
            trackOffsets: audio.map { $0.startLBA + 150 }
        )
    }

    /// The MusicBrainz DiscID: SHA-1 over the hex-formatted TOC, base64 with
    /// the MusicBrainz alphabet (+ → . , / → _ , = → -). Always 28 characters.
    public var musicBrainzDiscID: String {
        var input = String(format: "%02X%02X", firstTrack, lastTrack)
        var offsets = [Int](repeating: 0, count: 100)
        offsets[0] = leadOutOffset
        for (i, offset) in trackOffsets.enumerated() {
            offsets[firstTrack + i] = offset
        }
        for offset in offsets {
            input += String(format: "%08X", offset)
        }

        let digest = Insecure.SHA1.hash(data: Data(input.utf8))
        let base64 = Data(digest).base64EncodedString()
        return String(base64.map { char in
            switch char {
            case "+": "."
            case "/": "_"
            case "=": "-"
            default: char
            }
        })
    }

    /// The TOC string used for MusicBrainz fuzzy lookups and submission URLs:
    /// "first last leadout offset1 offset2 ...".
    public var musicBrainzTOCString: String {
        ([firstTrack, lastTrack, leadOutOffset] + trackOffsets)
            .map(String.init)
            .joined(separator: " ")
    }

    /// The classic FreeDB/CDDB 8-digit hex disc ID (used by CTDB/AccurateRip).
    public var freeDBDiscID: String {
        func digitSum(_ n: Int) -> Int {
            var n = n / 75, sum = 0
            while n > 0 {
                sum += n % 10
                n /= 10
            }
            return sum
        }
        // Unsigned arithmetic: n can have its high bit set, which would
        // overflow a signed 32-bit intermediate (found on a real disc).
        let n = UInt32(trackOffsets.reduce(0) { $0 + digitSum($1) } % 0xFF)
        let totalSeconds = UInt32(leadOutOffset / 75 - trackOffsets[0] / 75)
        let id = n << 24 | totalSeconds << 8 | UInt32(trackOffsets.count)
        return String(format: "%08x", id)
    }
}
