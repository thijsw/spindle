import DiscDrive
import Foundation
import Metadata
import RipEngine
import Verification

/// Renders the archival rip log for one disc: which hardware read it, with
/// which engine policy, and exactly which checksums and database verdicts
/// every track ended up with. Plain text with a stable layout, one file per
/// album, delivered next to the audio.
public struct RipLog: Sendable {
    public var ripDate: Date
    public var appVersion: String
    public var drive: DriveIdentity?
    public var configuration: RipConfiguration
    public var toc: TOC
    public var discTOC: DiscTOC?
    public var album: ResolvedAlbum?
    public var outcome: VerifiedRipper.Outcome
    public var ripDuration: Duration?

    public init(
        ripDate: Date,
        appVersion: String = RipLog.currentAppVersion,
        drive: DriveIdentity?,
        configuration: RipConfiguration,
        toc: TOC,
        discTOC: DiscTOC?,
        album: ResolvedAlbum?,
        outcome: VerifiedRipper.Outcome,
        ripDuration: Duration? = nil
    ) {
        self.ripDate = ripDate
        self.appVersion = appVersion
        self.drive = drive
        self.configuration = configuration
        self.toc = toc
        self.discTOC = discTOC
        self.album = album
        self.outcome = outcome
        self.ripDuration = ripDuration
    }

    /// The bundle's marketing version ("dev" outside an app bundle).
    public static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    public func render() -> String {
        var lines: [String] = []
        func add(_ label: String, _ value: String) {
            lines.append(label.padding(toLength: 13, withPad: " ", startingAt: 0) + ": " + value)
        }

        lines.append("Spindle \(appVersion) — rip log")
        lines.append("")
        add("Ripped on", ripDate.formatted(.iso8601))
        if let ripDuration {
            add("Rip time", Self.clock(seconds: Int(ripDuration.components.seconds)))
        }
        add("Drive", drive.map { "\($0.displayName) [\($0.revision)]" } ?? "unknown")
        add("Read offset", String(format: "%+d samples", configuration.sampleOffset))
        add("Rip mode", modeDescription)
        add("C2 pointers", c2Description)
        if let limit = configuration.trackTimeLimit {
            add("Track limit", "\(limit.components.seconds) s")
        }
        lines.append("")

        if let album {
            add("Album", "\(album.albumArtist) — \(album.album)")
            if let date = album.date { add("Released", date) }
            add("Disc", "\(album.discNumber)/\(album.discTotal)")
            if let mbid = album.releaseMBID {
                add("MusicBrainz", "https://musicbrainz.org/release/\(mbid)")
            }
        }
        if let discTOC {
            add("DiscID", discTOC.musicBrainzDiscID)
            add("FreeDB ID", discTOC.freeDBDiscID)
        }
        lines.append("")

        lines.append("TOC (lead-out \(toc.leadOutLBA))")
        lines.append("  track  type   start LBA   length  duration  ")
        for track in toc.tracks {
            let length = toc.lengthInSectors(of: track)
            var line = String(
                format: "     %02d  %@  %9d  %7d  %@",
                track.number,
                track.isAudio ? "audio" : "data ",
                track.startLBA,
                length,
                Self.clock(seconds: length / 75)
            )
            if track.hasPreEmphasis { line += "  pre-emphasis" }
            lines.append(line)
        }
        lines.append("")

        lines.append("Tracks")
        for track in outcome.tracks.sorted(by: { $0.trackNumber < $1.trackNumber }) {
            var line = String(
                format: "  %02d  CRC32 %08X  ARv1 %08X  ARv2 %08X  CTDB %08X",
                track.trackNumber,
                track.checksums.crc32,
                track.checksums.accurateRipV1,
                track.checksums.accurateRipV2,
                track.checksums.ctdbCRC32
            )
            line += "  " + verdictDescription(for: track.trackNumber)
            lines.append(line)
            var notes: [String] = []
            if outcome.reRippedTracks.contains(track.trackNumber) { notes.append("secure re-rip") }
            if track.rereads > 0 { notes.append("\(track.rereads) re-reads") }
            if !track.unrecoverableSectors.isEmpty {
                notes.append("\(track.unrecoverableSectors.count) unrecoverable sectors (zero-filled)")
            }
            if !notes.isEmpty { lines.append("      " + notes.joined(separator: ", ")) }
        }
        for number in outcome.failedTracks.sorted() {
            lines.append(String(format: "  %02d  NOT RIPPED — unreadable within the time limit", number))
        }
        lines.append("")

        if let verification = outcome.verification {
            add("Verification", verification.summary)
            if let match = verification.discMatch {
                add("Disc match", "CTDB entry \(match.id) (confidence \(match.confidence))")
            }
        } else {
            add("Verification", "none (no database available)")
        }
        add("Strategy", outcome.strategy)

        let preEmphasis = toc.audioTracks.filter(\.hasPreEmphasis).map(\.number)
        if !preEmphasis.isEmpty {
            lines.append("")
            lines.append(
                "Note: track(s) \(preEmphasis.map(String.init).joined(separator: ", ")) carry "
                    + "pre-emphasis; the audio was ripped as stored (no de-emphasis applied)."
            )
        }
        if outcome.c2Unreliable {
            lines.append("")
            lines.append("Warning: the drive's C2 error reporting was caught lying during this rip.")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private var modeDescription: String {
        switch configuration.mode {
        case .burst:
            "burst (single pass)"
        case .secure(let maxRetries, let agreeingPasses):
            "secure, verify-first (burst + database check; up to \(maxRetries) retries, \(agreeingPasses) agreeing passes on re-rips)"
        }
    }

    private var c2Description: String {
        if outcome.c2Unreliable { return "trusted at first, caught lying mid-rip — fell back to compare mode" }
        return configuration.allowC2 ? "trusted when the drive's C2 probe passes" : "disabled for this drive"
    }

    private func verdictDescription(for trackNumber: Int) -> String {
        guard let verdict = outcome.verification?.trackVerdicts[trackNumber] else { return "" }
        switch verdict {
        case .accuratelyRipped(let confidence): return "✓ verified (confidence \(confidence))"
        case .differs(let best): return "✗ differs from database (best confidence \(best))"
        case .notInDatabase: return "not in database"
        }
    }

    private static func clock(seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
