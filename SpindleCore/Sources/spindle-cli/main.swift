import DiscDrive
import Encoding
import Foundation
import Metadata
import Naming
import RipEngine
import SpindleCore
import Transfer
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
    --no-c2         never trust the drive's C2 error pointers
    --give-up <s>   abandon a track after s seconds (default 300, 0 = never)

  encode <wavdir> [options]
                    encode staged track WAVs (track01.wav…) to FLAC/ALAC
    --out <dir>     library root (default: ./library)
    --format <f>    flac, alac, or both (default: flac)
    --toc "<str>"   MusicBrainz TOC string for metadata lookup
    --pick <n>      candidate to use when several match (default: best)

  scan-offset <wavdir> [disk]
                    find the drive's read offset by testing an offset-0 rip
                    against the CUETools database at many candidate offsets
  push <dir> [options]
                    upload a directory tree to a destination
    --to <dest>     folder path, or sftp://user@host[:port]/remote/path
    --key <file>    SSH private key (default: password via
                    SPINDLE_SFTP_PASSWORD or saved Keychain entry)
    --save-password store the password in the Keychain for later runs

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
    var allowC2 = true
    var giveUpSeconds = 300

    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--out":
            i += 1
            guard i < rest.count else { fail("--out needs a value") }
            outDir = URL(fileURLWithPath: rest[i])
        case "--fast":
            mode = .burst
        case "--no-c2":
            allowC2 = false
        case "--give-up":
            i += 1
            guard i < rest.count, let s = Int(rest[i]) else { fail("--give-up needs seconds") }
            giveUpSeconds = s
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
        guard let track = toc.tracks.first(where: { $0.number == onlyTrack && $0.isAudio }) else {
            fail("No audio track \(onlyTrack) on this disc.")
        }
        // Keep the track's real end: with later tracks filtered out, its
        // length would otherwise extend to the session lead-out.
        let end = track.startLBA + toc.lengthInSectors(of: track)
        toc = TOC(
            tracks: [track],
            sessionLeadOuts: [track.session: end],
            firstSession: track.session,
            lastSession: track.session
        )
    }

    if offset == 0,
       let identity = DiscEnumerator.driveIdentity(forMediaBSDName: bsd),
       let suggestion = DriveOffsetTable.suggestion(for: identity) {
        print("note: no --offset given; \(identity.displayName) drives typically need \(suggestion.samples). Ripping with 0.")
    }

    let config = RipConfiguration(
        mode: mode,
        sampleOffset: offset,
        allowC2: allowC2,
        trackTimeLimit: giveUpSeconds > 0 ? .seconds(giveUpSeconds) : nil
    )
    let started = Date()
    print("Ripping \(toc.audioTracks.count) tracks to \(outDir.path) (\(mode == .burst ? "burst" : "verify-first secure"))…")

    // The CTDB TOC must describe the whole disc, so single-track rips skip
    // database verification.
    let verifier: CTDBVerifier? = onlyTrack == nil
        ? CTDBVerifier(userAgent: "Spindle/0.1 ( thijs@wijnmaalen.name )")
        : nil

    let printer = ProgressPrinter()
    let ripper = VerifiedRipper(device: drive, configuration: config, verifier: verifier)
    let outcome = try await ripper.rip(toc: toc, to: outDir) { progress in
        printer.print(progress)
    }
    print("")
    for track in outcome.tracks {
        var line = String(
            format: "track %02d  crc32 %08X  ARv1 %08X  ARv2 %08X  CTDB %08X",
            track.trackNumber,
            track.checksums.crc32,
            track.checksums.accurateRipV1,
            track.checksums.accurateRipV2,
            track.checksums.ctdbCRC32
        )
        var notes: [String] = []
        if outcome.reRippedTracks.contains(track.trackNumber) { notes.append("secure re-rip") }
        if track.rereads > 0 { notes.append("\(track.rereads) re-reads") }
        if !notes.isEmpty { line += "  (\(notes.joined(separator: ", ")))" }
        if !track.unrecoverableSectors.isEmpty {
            line += "  ⚠︎ \(track.unrecoverableSectors.count) unrecoverable sectors"
        }
        print(line)
    }
    print(String(format: "Ripped in %.1fs. %@", -started.timeIntervalSinceNow, outcome.strategy))
    if !outcome.failedTracks.isEmpty {
        print("✗ Gave up on track(s) \(outcome.failedTracks.map(String.init).joined(separator: ", ")) — not ripped within the time limit (--give-up to adjust).")
    }
    if outcome.c2Unreliable {
        print("⚠︎ This drive's C2 error reporting lied mid-rip; the engine fell back to compare mode. Future rips should disable C2 for this drive.")
    }

    if let verification = outcome.verification {
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

case "scan-offset":
    let rest = Array(arguments.dropFirst())
    guard let wavDir = rest.first, !wavDir.hasPrefix("--") else {
        fail("scan-offset needs a directory of trackNN.wav files")
    }
    let bsd = resolveDisc(rest.dropFirst().first)
    let drive = try CDDrive(bsdName: bsd)
    let toc = try TOC.parse(fullTOC: try await drive.readFullTOC())

    let wavURLs = (try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: wavDir), includingPropertiesForKeys: nil
    ))?.filter { $0.pathExtension == "wav" && $0.lastPathComponent.hasPrefix("track") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    guard wavURLs.count == toc.audioTracks.count else {
        fail("Found \(wavURLs.count) WAVs but the disc has \(toc.audioTracks.count) audio tracks.")
    }

    print("Querying CTDB…")
    let ctdbClient = CTDBClient(userAgent: "Spindle/0.1 ( thijs@wijnmaalen.name )")
    let entries = try await ctdbClient.lookup(toc: toc)
    guard !entries.isEmpty else {
        fail("Disc not in CTDB — cannot determine the offset from this disc.")
    }
    print("\(entries.count) database entries. Scanning \(OffsetScanner.commonOffsets.count) candidate offsets…")

    let scanStarted = Date()
    let candidates = try OffsetScanner.scan(wavURLs: wavURLs, toc: toc, entries: entries)
    print(String(format: "Scanned in %.1fs.\n", -scanStarted.timeIntervalSinceNow))

    for candidate in candidates.prefix(5) {
        print(String(
            format: "  offset %+5d  %2d/%d tracks match  (confidence %d)%@",
            candidate.offset,
            candidate.matchedTracks,
            candidate.totalTracks,
            candidate.confidence,
            candidate.isFullMatch ? "  ← full match" : ""
        ))
    }
    if let best = candidates.first {
        let failing = best.trackVerdicts
            .filter { if case .accuratelyRipped = $0.value { false } else { true } }
            .keys.sorted()
        if best.isFullMatch {
            print("\nDrive read offset: \(best.offset >= 0 ? "+" : "")\(best.offset) samples.")
        } else {
            print("\nBest candidate \(best.offset >= 0 ? "+" : "")\(best.offset): tracks \(failing.map(String.init).joined(separator: ", ")) don't match any entry — damage, or a pressing difference at the disc edges.")
        }
        if let identity = DiscEnumerator.driveIdentity(forMediaBSDName: bsd) {
            print("Set this for \(identity.displayName) in Settings → Ripping.")
        }
    }

case "bench":
    // Hidden: isolates rip-loop throughput layer by layer.
    let bsd = resolveDisc(arguments.dropFirst().first)
    let drive = try CDDrive(bsdName: bsd)
    try? await drive.setSpeed(0xFFFF)
    let start = 60000
    let total = 1500
    let chunk = 150

    func bench(_ label: String, _ body: () async throws -> Void) async rethrows {
        let t0 = ContinuousClock.now
        try await body()
        let dt = Double((ContinuousClock.now - t0).components.attoseconds) / 1e18
            + Double((ContinuousClock.now - t0).components.seconds) * 0 // avoid drift; use duration directly below
        _ = dt
        let elapsed = ContinuousClock.now - t0
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let kbs = Double(total) * 2352 / seconds / 1000
        print(String(format: "%@: %6.1f KB/s (%.1fx)", label, kbs, kbs / 176.4))
    }

    try await bench("1. actor readSectors only       ") {
        var lba = start
        while lba < start + total {
            _ = try await drive.readSectors(lba ..< min(lba + chunk, start + total), areas: .user)
            lba += chunk
        }
    }

    try await bench("2. + allAudio + checksums       ") {
        var lba = start + 2000
        let end = start + 2000 + total
        var checksums = ChecksumAccumulator(totalSamples: total * 588, isFirstTrack: false, isLastTrack: false)
        while lba < end {
            let buffer = try await drive.readSectors(lba ..< min(lba + chunk, end), areas: .user)
            checksums.update(buffer.allAudio())
            lba += chunk
        }
        _ = checksums.finalize()
    }

    try await bench("3. + WAV write                  ") {
        var lba = start + 4000
        let end = start + 4000 + total
        let writer = try WAVWriter(
            url: URL(fileURLWithPath: "/tmp/spindle-bench.wav"),
            expectedDataBytes: total * 2352
        )
        var checksums = ChecksumAccumulator(totalSamples: total * 588, isFirstTrack: false, isLastTrack: false)
        while lba < end {
            let buffer = try await drive.readSectors(lba ..< min(lba + chunk, end), areas: .user)
            let audio = buffer.allAudio()
            checksums.update(audio)
            try writer.append(audio)
            lba += chunk
        }
        try writer.finish()
        try? FileManager.default.removeItem(atPath: "/tmp/spindle-bench.wav")
    }

    try await bench("4. full TrackRipper path        ") {
        let toc = TOC(
            tracks: [TOCTrack(number: 1, session: 1, startLBA: start + 6000, isAudio: true, hasPreEmphasis: false)],
            sessionLeadOuts: [1: start + 6000 + total],
            firstSession: 1,
            lastSession: 1
        )
        let ripper = TrackRipper(
            device: drive,
            config: RipConfiguration(mode: .burst),
            readableSectors: 0 ..< start + 6000 + total,
            useC2: false
        )
        _ = try await ripper.rip(
            track: toc.tracks[0], toc: toc, isFirstAudio: false, isLastAudio: false,
            to: URL(fileURLWithPath: "/tmp/spindle-bench2.wav"),
            progress: { _ in }
        )
        try? FileManager.default.removeItem(atPath: "/tmp/spindle-bench2.wav")
    }

case "bench-sustained":
    // Hidden: reads a long span and prints the rate of each 1500-sector
    // window, with the DriveMonitor hold active like the real rip command.
    let bsd = resolveDisc(arguments.dropFirst().first)
    let monitor = try DriveMonitor()
    try? await monitor.hold(bsdName: bsd)
    defer { monitor.release(bsdName: bsd) }
    let drive = try CDDrive(bsdName: bsd)
    try? await drive.setSpeed(0xFFFF)

    let start = 14011 // track 2 start
    let total = 12000
    let chunk = 150
    var lba = start
    var windowStart = ContinuousClock.now
    var windowSectors = 0
    while lba < start + total {
        _ = try await drive.readSectors(lba ..< min(lba + chunk, start + total), areas: .user)
        lba += chunk
        windowSectors += chunk
        if windowSectors >= 1500 {
            let elapsed = ContinuousClock.now - windowStart
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let kbs = Double(windowSectors) * 2352 / seconds / 1000
            print(String(format: "  lba %6d  %6.1f KB/s (%.1fx)", lba, kbs, kbs / 176.4))
            windowStart = ContinuousClock.now
            windowSectors = 0
        }
    }

case "calibrate-skips":
    // Hidden diagnostic: brute-forces the CTDB edge-skip parameters against
    // a known-good rip + database entries, to pin down the exact prefix
    // (first track) and suffix (last track) semantics.
    let rest = Array(arguments.dropFirst())
    guard rest.count >= 2, let knownOffset = Int(rest[1]) else {
        fail("usage: calibrate-skips <wavdir> <offset> [disk]")
    }
    let wavDir = rest[0]
    let bsd = resolveDisc(rest.dropFirst(2).first)
    let drive = try CDDrive(bsdName: bsd)
    let toc = try TOC.parse(fullTOC: try await drive.readFullTOC())
    let audio = toc.audioTracks

    let wavURLs = (try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: wavDir), includingPropertiesForKeys: nil
    ))?.filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    guard wavURLs.count == audio.count else { fail("WAV count mismatch") }

    let ctdb = CTDBClient(userAgent: "Spindle/0.1 ( thijs@wijnmaalen.name )")
    let entries = try await ctdb.lookup(toc: toc)
    print("\(entries.count) CTDB entries.")

    let firstWAV = try Data(contentsOf: wavURLs[0], options: .alwaysMapped).dropFirst(44)
    let lastWAV = try Data(contentsOf: wavURLs[wavURLs.count - 1], options: .alwaysMapped).dropFirst(44)
    let lastStart = audio[audio.count - 1].startLBA
    let totalSamples = (toc.sessionLeadOuts[audio[0].session] ?? toc.leadOutLBA) * 588
    let track2Start = audio[1].startLBA

    print("Scanning prefix candidates for track 1 (offset \(knownOffset))…")
    for prefix in stride(from: 0, through: 35280, by: 147) {
        let startByte = (prefix + knownOffset) * 4
        let endByte = (track2Start * 588 + knownOffset) * 4
        guard startByte >= 0, endByte <= firstWAV.count else { continue }
        let crc = CRC32.checksum(firstWAV.subdata(
            in: firstWAV.startIndex + startByte ..< firstWAV.startIndex + endByte
        ))
        for entry in entries where !entry.trackCRC32s.isEmpty && entry.trackCRC32s[0] == crc {
            print(String(format: "  ✓ prefix %5d samples matches entry %@ (confidence %d)", prefix, entry.id, entry.confidence))
        }
    }

    print("Scanning suffix candidates for track \(audio.count)…")
    for suffix in stride(from: 0, through: 11760, by: 294) {
        let startByte = (lastStart * 588 + knownOffset - lastStart * 588) * 4 // 0 within last WAV, shifted below
        let windowStart = knownOffset * 4
        let windowEnd = (totalSamples - suffix + knownOffset - lastStart * 588) * 4
        guard windowStart >= 0, windowEnd <= lastWAV.count, windowEnd > windowStart else { continue }
        _ = startByte
        let crc = CRC32.checksum(lastWAV.subdata(
            in: lastWAV.startIndex + windowStart ..< lastWAV.startIndex + windowEnd
        ))
        for entry in entries where entry.trackCRC32s.count == audio.count && entry.trackCRC32s[audio.count - 1] == crc {
            print(String(format: "  ✓ suffix %5d samples matches entry %@ (confidence %d)", suffix, entry.id, entry.confidence))
        }
    }
    print("Done. (Step 294 = quarter sector; rerun with finer steps around hits if needed.)")

case "push":
    let rest = Array(arguments.dropFirst())
    var sourceDir: String?
    var destSpec: String?
    var keyFile: String?
    var savePassword = false

    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--to":
            i += 1
            guard i < rest.count else { fail("--to needs a destination") }
            destSpec = rest[i]
        case "--key":
            i += 1
            guard i < rest.count else { fail("--key needs a file path") }
            keyFile = rest[i]
        case "--save-password":
            savePassword = true
        default:
            if sourceDir == nil, !rest[i].hasPrefix("--") {
                sourceDir = rest[i]
            } else {
                fail("Unknown option: \(rest[i])")
            }
        }
        i += 1
    }

    guard let sourceDir, let destSpec else { fail("push needs <dir> and --to <dest>") }
    let sourceRoot = URL(fileURLWithPath: sourceDir)

    let destination: any Destination
    if destSpec.hasPrefix("sftp://") {
        guard let url = URL(string: destSpec),
              let host = url.host,
              let user = url.user
        else { fail("SFTP destination must look like sftp://user@host[:port]/remote/path") }
        var config = SFTPConfig(
            host: host,
            port: url.port ?? 22,
            username: user,
            remotePath: url.path.isEmpty ? "." : url.path
        )
        var secret = ProcessInfo.processInfo.environment["SPINDLE_SFTP_PASSWORD"]
            ?? KeychainStore.load(account: config.keychainAccount)
        if let keyFile {
            config.authentication = .privateKeyFile(path: keyFile)
        } else if secret == nil {
            print("Password for \(config.keychainAccount): ", terminator: "")
            secret = readLine(strippingNewline: true)
        }
        if savePassword, let secret, case .password = config.authentication {
            try KeychainStore.save(secret: secret, account: config.keychainAccount)
            print("Password saved to Keychain.")
        }
        destination = SFTPDestination(config: config, secret: secret)
    } else {
        destination = LocalFolderDestination(path: destSpec)
    }

    let testResult = await destination.test()
    switch testResult {
    case .success(let message): print(message)
    case .failure(let error): fail("Destination test failed: \(error)")
    }

    let resolvedRoot = sourceRoot.resolvingSymlinksInPath().path
    let enumerator = FileManager.default.enumerator(
        at: sourceRoot, includingPropertiesForKeys: [.isRegularFileKey]
    )
    var files: [(URL, String)] = []
    while let item = enumerator?.nextObject() as? URL {
        guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              !item.lastPathComponent.hasPrefix(".")
        else { continue }
        let itemPath = item.resolvingSymlinksInPath().path
        guard itemPath.hasPrefix(resolvedRoot + "/") else { continue }
        files.append((item, String(itemPath.dropFirst(resolvedRoot.count + 1))))
    }
    files.sort { $0.1 < $1.1 }
    guard !files.isEmpty else { fail("Nothing to upload in \(sourceDir)") }

    print("Uploading \(files.count) files…")
    let pushStarted = Date()
    for (url, relative) in files {
        try await destination.upload(file: url, toRelativePath: relative, progress: nil)
        print("  \(relative)")
    }
    await destination.close()
    print(String(format: "Uploaded in %.1fs.", -pushStarted.timeIntervalSinceNow))

case "prefs-check":
    // Hidden diagnostic: proves the preferences file decodes (a malformed
    // file silently falls back to defaults, losing drive calibration).
    let prefs = PreferencesStore.load()
    print("ripMode: \(prefs.ripMode.rawValue), formats: \(prefs.formats.map(\.rawValue))")
    print("driveOffsets: \(prefs.driveOffsets)")
    print("c2 denylist: \(prefs.drivesWithUnreliableC2 ?? [])")
    print("destination: \(prefs.destination?.displayName ?? "none")")

default:
    print(usage)
    exit(64)
}
