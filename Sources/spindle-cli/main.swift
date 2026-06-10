import DiscDrive
import Encoding
import Foundation
import Metadata
import Naming
import RipEngine
import Verification

// Debug/development CLI. Each milestone adds a subcommand so every subsystem
// can be exercised headless before the app UI exists.

let usage = """
usage: spindle-cli <command>

commands:
  detect            watch for disc insertions/removals (Ctrl-C to stop)
  drives            list present CD media and drive identity
  toc [disk]        read and print the table of contents
  discid [disk]     compute the MusicBrainz DiscID and TOC string
  identify [disk] [options]
                    look up the disc on MusicBrainz
    --pick <n>      show full tags for candidate n
    --art <file>    download cover art for the picked release
    --toc "<str>"   use a TOC string ("first last leadout offsets…")
                    instead of reading a disc
  rip [disk] [options]
                    rip audio tracks to WAV files
    --out <dir>     output directory (default: ./rip)
    --fast          burst mode (default: secure)
    --offset <n>    sample offset correction (default: 0)
    --track <n>     rip a single track

  encode <wavdir> [options]
                    encode staged track WAVs (track01.wav…) to FLAC/ALAC
    --out <dir>     library root (default: ./library)
    --format <f>    flac, alac, or both (default: flac)
    --toc "<str>"   MusicBrainz TOC string for metadata lookup
    --pick <n>      candidate to use when several match (default: best)

[disk] is a BSD name like disk4; defaults to the first CD medium found.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func resolveDisc(_ argument: String?) -> String {
    if let argument { return argument }
    guard let first = DiscEnumerator.presentCDMedia().first else {
        fail("No CD medium present. Insert a disc or pass a BSD name.")
    }
    return first
}

func loadTOC(bsdName: String) async throws -> TOC {
    let drive = try CDDrive(bsdName: bsdName)
    let raw = try await drive.readFullTOC()
    return try TOC.parse(fullTOC: raw)
}

/// Serializes one-line progress output from the rip callback.
final class ProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastLine = ""

    func print(_ progress: RipProgress) {
        lock.lock()
        defer { lock.unlock() }
        let line = String(
            format: "\rtrack %02d  %3d%%%@",
            progress.trackNumber,
            Int(progress.fraction * 100),
            progress.rereads > 0 ? "  (\(progress.rereads) re-reads)" : ""
        )
        guard line != lastLine else { return }
        lastLine = line
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}

func formatMSF(_ sectors: Int) -> String {
    let s = sectors + 150
    return String(format: "%02d:%02d.%02d", s / (60 * 75), (s / 75) % 60, s % 75)
}

let arguments = CommandLine.arguments.dropFirst()
guard let command = arguments.first else {
    print(usage)
    exit(0)
}

switch command {
case "detect":
    let monitor = try DriveMonitor()
    print("Watching for CD media (Ctrl-C to stop)…")
    for bsd in DiscEnumerator.presentCDMedia() {
        print("already present: \(bsd)")
    }
    for await event in monitor.events {
        switch event {
        case .discAppeared(let bsd): print("appeared:    \(bsd)")
        case .discDisappeared(let bsd): print("disappeared: \(bsd)")
        }
    }

case "drives":
    let media = DiscEnumerator.presentCDMedia()
    if media.isEmpty { print("No CD media present.") }
    for bsd in media {
        if let identity = DiscEnumerator.driveIdentity(forMediaBSDName: bsd) {
            var line = "\(bsd): \(identity.displayName) [\(identity.revision)]"
            if let suggestion = DriveOffsetTable.suggestion(for: identity) {
                line += " — suggested read offset: \(suggestion.samples) samples (unverified)"
            }
            print(line)
        } else {
            print("\(bsd): unknown drive")
        }
    }

case "toc":
    let bsd = resolveDisc(arguments.dropFirst().first)
    let toc = try await loadTOC(bsdName: bsd)
    print("Disc in \(bsd): sessions \(toc.firstSession)–\(toc.lastSession), \(toc.tracks.count) tracks")
    for track in toc.tracks {
        let length = toc.lengthInSectors(of: track)
        let seconds = Double(length) / 75.0
        print(String(
            format: "  %2d  %@  start %6d  length %6d (%d:%04.1f)  %@%@",
            track.number,
            track.isAudio ? "audio" : "data ",
            track.startLBA,
            length,
            Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60),
            "session \(track.session)",
            track.hasPreEmphasis ? ", pre-emphasis" : ""
        ))
    }
    print("  lead-out at \(toc.leadOutLBA) (\(formatMSF(toc.leadOutLBA)))")

case "discid":
    let bsd = resolveDisc(arguments.dropFirst().first)
    let toc = try await loadTOC(bsdName: bsd)
    guard let discTOC = DiscTOC(toc: toc) else {
        fail("Disc has no audio tracks.")
    }
    print("MusicBrainz DiscID: \(discTOC.musicBrainzDiscID)")
    print("FreeDB ID:          \(discTOC.freeDBDiscID)")
    print("TOC string:         \(discTOC.musicBrainzTOCString)")
    print("Lookup URL:         https://musicbrainz.org/ws/2/discid/\(discTOC.musicBrainzDiscID)?fmt=json")

case "identify":
    let rest = Array(arguments.dropFirst())
    var disk: String?
    var pick: Int?
    var artPath: String?
    var tocString: String?

    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--pick":
            i += 1
            guard i < rest.count, let n = Int(rest[i]) else { fail("--pick needs a number") }
            pick = n
        case "--art":
            i += 1
            guard i < rest.count else { fail("--art needs a file path") }
            artPath = rest[i]
        case "--toc":
            i += 1
            guard i < rest.count else { fail("--toc needs a TOC string") }
            tocString = rest[i]
        default:
            if disk == nil, !rest[i].hasPrefix("--") {
                disk = rest[i]
            } else {
                fail("Unknown option: \(rest[i])")
            }
        }
        i += 1
    }

    let discTOC: DiscTOC
    let audioTrackCount: Int

    if let tocString {
        let numbers = tocString.split(separator: " ").compactMap { Int($0) }
        guard numbers.count >= 4 else { fail("TOC string needs: first last leadout offsets…") }
        let parsed = DiscTOC(
            firstTrack: numbers[0],
            lastTrack: numbers[1],
            leadOutOffset: numbers[2],
            trackOffsets: Array(numbers.dropFirst(3))
        )
        guard parsed.trackOffsets.count == parsed.lastTrack - parsed.firstTrack + 1 else {
            fail("TOC string has \(parsed.trackOffsets.count) offsets for tracks \(parsed.firstTrack)–\(parsed.lastTrack)")
        }
        discTOC = parsed
        audioTrackCount = parsed.trackOffsets.count
    } else {
        let bsd = resolveDisc(disk)
        let drive = try CDDrive(bsdName: bsd)
        let toc = try TOC.parse(fullTOC: try await drive.readFullTOC())
        guard let fromDisc = DiscTOC(toc: toc) else { fail("Disc has no audio tracks.") }
        discTOC = fromDisc
        audioTrackCount = toc.audioTracks.count

        if let packs = ((try? await drive.readCDTextPacks()) ?? nil),
           let cdText = CDTextParser.parse(packs: packs) {
            print("CD-TEXT: \(cdText.albumPerformer ?? "?") — \(cdText.albumTitle ?? "?")")
        }
    }

    print("DiscID \(discTOC.musicBrainzDiscID) — querying MusicBrainz…")
    let client = MusicBrainzClient(userAgent: "Spindle/0.1 ( thijs@wijnmaalen.name )")
    let result = try await client.lookup(disc: discTOC)

    let releases: [MBRelease]
    switch result {
    case .matched(let r):
        print("Exact DiscID match: \(r.count) release(s)")
        releases = r
    case .fuzzy(let r):
        print("DiscID unknown; fuzzy TOC match: \(r.count) candidate(s)")
        releases = r
    case .none:
        print("No matches on MusicBrainz.")
        exit(0)
    }

    let scorer = ReleaseScorer()
    let ranked = scorer.rank(releases, discID: discTOC.musicBrainzDiscID, audioTrackCount: audioTrackCount)
    for (index, item) in ranked.enumerated() {
        let r = item.release
        let media = (r.media ?? []).first
        print(String(
            format: "%2d. %@ — %@ (%@, %@, %@, %@ tracks)%@",
            index + 1,
            (r.artistCredit ?? []).joinedName,
            r.title,
            r.date ?? "no date",
            r.country ?? "??",
            media?.format ?? "?",
            String(media?.trackCount ?? 0),
            index == 0 ? String(format: "  [confidence %.0f%%]", item.confidence * 100) : ""
        ))
    }

    if let pick {
        guard pick >= 1, pick <= ranked.count else { fail("--pick out of range") }
        let release = ranked[pick - 1].release
        guard let album = ResolvedAlbum(
            release: release,
            discID: discTOC.musicBrainzDiscID,
            audioTrackCount: audioTrackCount
        ) else { fail("Could not resolve that release.") }

        print("\n\(album.albumArtist) — \(album.album)")
        print("\(album.date ?? "") \(album.label ?? "") \(album.catalogNumber ?? "") disc \(album.discNumber)/\(album.discTotal)")
        for track in album.tracks {
            print(String(format: "  %02d. %@ — %@", track.position, track.artist, track.title))
        }

        if let artPath {
            let artClient = CoverArtClient(userAgent: "Spindle/0.1 ( thijs@wijnmaalen.name )")
            if let art = await artClient.fetchArt(
                releaseMBID: album.releaseMBID,
                releaseGroupMBID: album.releaseGroupMBID,
                fallbackQuery: "\(album.albumArtist) \(album.album)"
            ) {
                try art.data.write(to: URL(fileURLWithPath: artPath))
                print("Cover art (\(art.source.rawValue), \(art.data.count / 1024) KB) → \(artPath)")
            } else {
                print("No cover art found.")
            }
        }
    }

case "rip":
    let rest = Array(arguments.dropFirst())
    var outDir = URL(fileURLWithPath: "rip")
    var mode = RipConfiguration.Mode.secureDefault
    var offset = 0
    var onlyTrack: Int?
    var disk: String?

    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--out":
            i += 1
            guard i < rest.count else { fail("--out needs a value") }
            outDir = URL(fileURLWithPath: rest[i])
        case "--fast":
            mode = .burst
        case "--offset":
            i += 1
            guard i < rest.count, let n = Int(rest[i]) else { fail("--offset needs a number") }
            offset = n
        case "--track":
            i += 1
            guard i < rest.count, let n = Int(rest[i]) else { fail("--track needs a number") }
            onlyTrack = n
        default:
            if disk == nil, !rest[i].hasPrefix("--") {
                disk = rest[i]
            } else {
                fail("Unknown option: \(rest[i])")
            }
        }
        i += 1
    }

    let bsd = resolveDisc(disk)

    // Unmount the cddafs volume so raw reads don't race the filesystem,
    // and keep it from re-mounting mid-rip.
    let monitor = try DriveMonitor()
    try? await monitor.hold(bsdName: bsd)
    defer { monitor.release(bsdName: bsd) }

    let drive = try CDDrive(bsdName: bsd)
    var toc = try TOC.parse(fullTOC: try await drive.readFullTOC())
    if let onlyTrack {
        guard toc.tracks.contains(where: { $0.number == onlyTrack && $0.isAudio }) else {
            fail("No audio track \(onlyTrack) on this disc.")
        }
        toc = TOC(
            tracks: toc.tracks.filter { $0.number == onlyTrack },
            sessionLeadOuts: toc.sessionLeadOuts,
            firstSession: toc.firstSession,
            lastSession: toc.lastSession
        )
    }

    if offset == 0,
       let identity = DiscEnumerator.driveIdentity(forMediaBSDName: bsd),
       let suggestion = DriveOffsetTable.suggestion(for: identity) {
        print("note: no --offset given; \(identity.displayName) drives typically need \(suggestion.samples). Ripping with 0.")
    }

    let config = RipConfiguration(mode: mode, sampleOffset: offset)
    let ripper = DiscRipper(device: drive, config: config)
    let started = Date()
    print("Ripping \(toc.audioTracks.count) tracks to \(outDir.path) (\(mode == .burst ? "burst" : "secure"))…")

    let printer = ProgressPrinter()
    let result = try await ripper.ripDisc(toc: toc, to: outDir) { progress in
        printer.print(progress)
    }
    print("")
    for track in result.tracks {
        var line = String(
            format: "track %02d  crc32 %08X  ARv1 %08X  ARv2 %08X  CTDB %08X",
            track.trackNumber,
            track.checksums.crc32,
            track.checksums.accurateRipV1,
            track.checksums.accurateRipV2,
            track.checksums.ctdbCRC32
        )
        if track.rereads > 0 { line += "  (\(track.rereads) re-reads)" }
        if !track.unrecoverableSectors.isEmpty {
            line += "  ⚠︎ \(track.unrecoverableSectors.count) unrecoverable sectors"
        }
        print(line)
    }
    print(String(format: "Ripped in %.1fs.", -started.timeIntervalSinceNow))

    if onlyTrack == nil {
        do {
            let verifier = CTDBVerifier(userAgent: "Spindle/0.1 ( thijs@wijnmaalen.name )")
            let checksums = result.tracks.reduce(into: [Int: TrackChecksums]()) {
                $0[$1.trackNumber] = $1.checksums
            }
            let verification = try await verifier.verify(
                toc: toc, trackChecksums: checksums, ctdbDiscCRC32: result.ctdbDiscCRC32
            )
            print(verification.summary)
            if let match = verification.discMatch {
                print("Whole-disc CRC matches CTDB entry \(match.id) (confidence \(match.confidence)).")
            }
            for (track, verdict) in verification.trackVerdicts.sorted(by: { $0.key < $1.key }) {
                switch verdict {
                case .accuratelyRipped(let confidence):
                    print(String(format: "  track %02d  ✓ verified (confidence %d)", track, confidence))
                case .differs(let best):
                    print(String(format: "  track %02d  ✗ differs from database (best confidence %d) — check drive offset", track, best))
                case .notInDatabase:
                    print(String(format: "  track %02d  not in database", track))
                }
            }
        } catch {
            print("CTDB verification unavailable: \(error)")
        }
    }

case "encode":
    let rest = Array(arguments.dropFirst())
    var wavDir: String?
    var outDir = URL(fileURLWithPath: "library")
    var formats: [AudioFormat] = [.flac]
    var tocString: String?
    var pick: Int?

    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--out":
            i += 1
            guard i < rest.count else { fail("--out needs a value") }
            outDir = URL(fileURLWithPath: rest[i])
        case "--format":
            i += 1
            guard i < rest.count else { fail("--format needs flac|alac|both") }
            switch rest[i] {
            case "flac": formats = [.flac]
            case "alac": formats = [.alac]
            case "both": formats = [.flac, .alac]
            default: fail("--format must be flac, alac, or both")
            }
        case "--toc":
            i += 1
            guard i < rest.count else { fail("--toc needs a TOC string") }
            tocString = rest[i]
        case "--pick":
            i += 1
            guard i < rest.count, let n = Int(rest[i]) else { fail("--pick needs a number") }
            pick = n
        default:
            if wavDir == nil, !rest[i].hasPrefix("--") {
                wavDir = rest[i]
            } else {
                fail("Unknown option: \(rest[i])")
            }
        }
        i += 1
    }

    guard let wavDir else { fail("encode needs a directory of trackNN.wav files") }
    let wavURLs = (try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: wavDir), includingPropertiesForKeys: nil
    ))?.filter { $0.pathExtension == "wav" && $0.lastPathComponent.hasPrefix("track") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    guard !wavURLs.isEmpty else { fail("No trackNN.wav files in \(wavDir)") }

    var album: ResolvedAlbum
    var art: CoverArt?
    if let tocString {
        let numbers = tocString.split(separator: " ").compactMap { Int($0) }
        guard numbers.count >= 4 else { fail("TOC string needs: first last leadout offsets…") }
        let discTOC = DiscTOC(
            firstTrack: numbers[0],
            lastTrack: numbers[1],
            leadOutOffset: numbers[2],
            trackOffsets: Array(numbers.dropFirst(3))
        )
        let client = MusicBrainzClient(userAgent: "Spindle/0.1 ( thijs@wijnmaalen.name )")
        let result = try await client.lookup(disc: discTOC)
        let releases: [MBRelease]
        switch result {
        case .matched(let r), .fuzzy(let r): releases = r
        case .none: releases = []
        }
        let ranked = ReleaseScorer().rank(
            releases, discID: discTOC.musicBrainzDiscID, audioTrackCount: wavURLs.count
        )
        let chosen: MBRelease?
        if let pick {
            guard pick >= 1, pick <= ranked.count else { fail("--pick out of range") }
            chosen = ranked[pick - 1].release
        } else {
            chosen = ranked.first?.release
        }
        if let chosen, let resolved = ResolvedAlbum(
            release: chosen, discID: discTOC.musicBrainzDiscID, audioTrackCount: wavURLs.count
        ) {
            album = resolved
            print("Tagging as: \(album.albumArtist) — \(album.album)")
            let artClient = CoverArtClient(userAgent: "Spindle/0.1 ( thijs@wijnmaalen.name )")
            art = await artClient.fetchArt(
                releaseMBID: album.releaseMBID,
                releaseGroupMBID: album.releaseGroupMBID,
                fallbackQuery: "\(album.albumArtist) \(album.album)"
            )
            if let art { print("Cover art: \(art.source.rawValue), \(art.data.count / 1024) KB") }
        } else {
            print("No MusicBrainz match; tagging as Unknown Album.")
            album = ResolvedAlbum.fallback(cdText: nil, discID: discTOC.musicBrainzDiscID, trackCount: wavURLs.count)
        }
    } else {
        album = ResolvedAlbum.fallback(cdText: nil, discID: nil, trackCount: wavURLs.count)
    }

    guard album.tracks.count == wavURLs.count else {
        fail("Release has \(album.tracks.count) tracks but \(wavURLs.count) WAVs found.")
    }

    let template = NamingTemplate.standard
    var albumFolder: URL?
    for (wav, track) in zip(wavURLs, album.tracks) {
        let tags = TrackTags(album: album, track: track)
        for format in formats {
            let relative = template.render(album: album, track: track) + "." + format.fileExtension
            let destination = outDir.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            albumFolder = destination.deletingLastPathComponent()
            let encoder: any TrackEncoder = format == .flac ? FLACEncoder() : ALACEncoder()
            try await encoder.encode(wav: wav, to: destination, tags: tags, art: art)
            print("  \(relative)")
        }
    }
    if let art, let albumFolder {
        try art.data.write(to: albumFolder.appendingPathComponent("cover.\(art.fileExtension)"))
        print("  cover.\(art.fileExtension)")
    }

default:
    print(usage)
    exit(64)
}
