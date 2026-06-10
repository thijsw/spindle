import Foundation

/// One track entry from a disc's table of contents.
public struct TOCTrack: Sendable, Hashable, Codable {
    public let number: Int
    public let session: Int
    /// Start of the track as a 0-based logical block address (MSF address minus
    /// the 150-frame standard pregap). Track 1 of a normal disc is LBA 0.
    public let startLBA: Int
    public let isAudio: Bool
    public let hasPreEmphasis: Bool

    public init(number: Int, session: Int, startLBA: Int, isAudio: Bool, hasPreEmphasis: Bool) {
        self.number = number
        self.session = session
        self.startLBA = startLBA
        self.isAudio = isAudio
        self.hasPreEmphasis = hasPreEmphasis
    }
}

/// Parsed table of contents of a CD.
public struct TOC: Sendable, Hashable, Codable {
    /// All tracks, sorted by track number.
    public let tracks: [TOCTrack]
    /// Lead-out of each session, keyed by session number, as 0-based LBA.
    public let sessionLeadOuts: [Int: Int]
    public let firstSession: Int
    public let lastSession: Int

    public init(tracks: [TOCTrack], sessionLeadOuts: [Int: Int], firstSession: Int, lastSession: Int) {
        self.tracks = tracks.sorted { $0.number < $1.number }
        self.sessionLeadOuts = sessionLeadOuts
        self.firstSession = firstSession
        self.lastSession = lastSession
    }

    /// Lead-out of the last session (end of disc), 0-based LBA.
    public var leadOutLBA: Int { sessionLeadOuts[lastSession] ?? 0 }

    public var audioTracks: [TOCTrack] { tracks.filter(\.isAudio) }

    /// Track length in sectors: distance to the next track in the same session,
    /// or to that session's lead-out for the last track of a session.
    public func lengthInSectors(of track: TOCTrack) -> Int {
        let next = tracks
            .filter { $0.session == track.session && $0.startLBA > track.startLBA }
            .map(\.startLBA)
            .min()
        let end = next ?? sessionLeadOuts[track.session] ?? track.startLBA
        return max(0, end - track.startLBA)
    }

    public func sectorRange(of track: TOCTrack) -> Range<Int> {
        track.startLBA ..< track.startLBA + lengthInSectors(of: track)
    }

    public var totalAudioSectors: Int {
        audioTracks.map(lengthInSectors(of:)).reduce(0, +)
    }
}

public enum TOCParseError: Error, CustomStringConvertible, Sendable {
    case tooShort
    case noTracks

    public var description: String {
        switch self {
        case .tooShort: "TOC response is too short to parse"
        case .noTracks: "TOC contains no track descriptors"
        }
    }
}

extension TOC {
    /// Parses the raw response of DKIOCCDREADTOC with format 2 (full TOC) and
    /// formatAsTime set, i.e. the MMC READ TOC/PMA/ATIP "full TOC" layout:
    /// a 4-byte header (16-bit big-endian data length, first session, last
    /// session) followed by 11-byte track descriptors with MSF addresses.
    public static func parse(fullTOC data: Data) throws -> TOC {
        guard data.count >= 4 else { throw TOCParseError.tooShort }

        let bytes = [UInt8](data)
        let dataLength = Int(bytes[0]) << 8 | Int(bytes[1])
        let firstSession = Int(bytes[2])
        let lastSession = Int(bytes[3])
        // dataLength counts the two session bytes plus the descriptors.
        let descriptorBytes = min(dataLength - 2, bytes.count - 4)

        var tracks: [TOCTrack] = []
        var leadOuts: [Int: Int] = [:]

        var i = 4
        while i + 11 <= 4 + descriptorBytes {
            defer { i += 11 }
            let session = Int(bytes[i])
            let adr = Int(bytes[i + 1]) >> 4
            let control = Int(bytes[i + 1]) & 0x0F
            let point = Int(bytes[i + 3])
            let pmin = Int(bytes[i + 8])
            let psec = Int(bytes[i + 9])
            let pframe = Int(bytes[i + 10])

            // Only Q-channel position descriptors (ADR 1) carry track/lead-out
            // start addresses; ADR 5 entries describe skip intervals etc.
            guard adr == 1 else { continue }

            let lba = (pmin * 60 + psec) * 75 + pframe - 150

            switch point {
            case 0x01...0x63:
                tracks.append(TOCTrack(
                    number: point,
                    session: session,
                    startLBA: lba,
                    isAudio: control & 0x04 == 0,
                    hasPreEmphasis: control & 0x01 != 0
                ))
            case 0xA2:
                leadOuts[session] = lba
            default:
                break // 0xA0/0xA1 (first/last track number) are implied by the entries
            }
        }

        guard !tracks.isEmpty else { throw TOCParseError.noTracks }

        return TOC(
            tracks: tracks,
            sessionLeadOuts: leadOuts,
            firstSession: firstSession,
            lastSession: lastSession
        )
    }
}
