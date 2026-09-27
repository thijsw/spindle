import DiscDrive
import Foundation
import Metadata
import RipEngine
import SpindleCore
import Verification

enum RipCommand {
    static let help = """
      rip [disk] [options]
                        rip audio tracks to WAV files, with the saved
                        per-drive offset and C2 verdict from Settings
        --out <dir>     output directory (default: ./rip)
        --fast          burst mode (default: secure)
        --offset <n>    sample offset correction (default: the saved offset, else 0)
        --track <n>     rip a single track
        --no-c2         never trust the drive's C2 error pointers
        --give-up <s>   abandon a track after s seconds (default \(defaultGiveUpSeconds), 0 = never)
    """

    private static var defaultGiveUpSeconds: Int {
        Int((RipConfiguration().trackTimeLimit ?? .zero) / .seconds(1))
    }

    static func run(_ args: ArraySlice<String>) async throws {
        var scanner = ArgumentScanner(args)
        var outDir = URL(fileURLWithPath: "rip")
        var fast = false
        var offset: Int?
        var onlyTrack: Int?
        var disk: String?
        var disallowC2 = false
        var giveUpSeconds = defaultGiveUpSeconds

        while let argument = scanner.next() {
            switch argument {
            case "--out": outDir = URL(fileURLWithPath: scanner.value(after: "--out"))
            case "--fast": fast = true
            case "--no-c2": disallowC2 = true
            case "--give-up": giveUpSeconds = scanner.intValue(after: "--give-up")
            case "--offset": offset = scanner.intValue(after: "--offset")
            case "--track": onlyTrack = scanner.intValue(after: "--track")
            default: disk = scanner.positional(argument, replacing: disk)
            }
        }

        let bsd = resolveDisc(disk)

        // Unmount the cddafs volume so raw reads don't race the filesystem,
        // and keep it from re-mounting mid-rip.
        let monitor = try DriveMonitor()
        try? await monitor.hold(bsdName: bsd)
        defer { monitor.release(bsdName: bsd) }

        var (drive, toc) = try await openDisc(bsdName: bsd)
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

        // The same configuration the app would use for this drive (saved
        // offset, C2 verdict, rip mode), with the flags layered on top.
        let identity = DiscEnumerator.driveIdentity(forMediaBSDName: bsd)
        var config = PreferencesStore.load().ripConfiguration(forDrive: identity?.offsetKey)
        if fast { config.mode = .burst }
        if let offset { config.sampleOffset = offset }
        if disallowC2 { config.allowC2 = false }
        config.trackTimeLimit = giveUpSeconds > 0 ? .seconds(giveUpSeconds) : nil

        if offset == nil, config.sampleOffset == 0,
           let identity, let suggestion = DriveOffsetTable.suggestion(for: identity) {
            print("note: no offset saved for \(identity.displayName); drives of this family typically need \(suggestion.samples). Ripping with 0.")
        }

        let started = Date()
        let isBurst = config.mode == .burst
        print("Ripping \(toc.audioTracks.count) tracks to \(outDir.path) (offset \(config.sampleOffset), \(isBurst ? "burst" : "verify-first secure"))…")

        // The CTDB TOC must describe the whole disc, so single-track rips skip
        // database verification.
        let verifier: CTDBVerifier? = onlyTrack == nil ? CTDBVerifier(userAgent: Spindle.userAgent) : nil

        let printer = ProgressPrinter()
        let ripper = VerifiedRipper(device: drive, configuration: config, verifier: verifier)
        let outcome = try await ripper.rip(toc: toc, to: outDir) { progress in
            printer.print(progress)
        }
        print("")
        report(outcome)
        print(String(format: "Ripped in %.1fs. %@", -started.timeIntervalSinceNow, outcome.summary))

        let log = RipLog(
            ripDate: started,
            drive: identity,
            configuration: config,
            toc: toc,
            discTOC: DiscTOC(toc: toc),
            album: nil,
            outcome: outcome,
            ripDuration: .seconds(-started.timeIntervalSinceNow)
        )
        let logURL = outDir.appendingPathComponent("rip.log")
        try log.render().write(to: logURL, atomically: true, encoding: .utf8)
        print("Log → \(logURL.path)")
    }

    private static func report(_ outcome: VerifiedRipper.Outcome) {
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
        if !outcome.failedTracks.isEmpty {
            print("✗ Gave up on track(s) \(outcome.failedTracks.map(String.init).joined(separator: ", ")) — not ripped within the time limit (--give-up to adjust).")
        }
        if outcome.c2Unreliable {
            print("⚠︎ This drive's C2 error reporting lied mid-rip; the engine fell back to compare mode. Future rips will skip C2 for this drive.")
        }
        if let error = outcome.verificationError {
            print("⚠︎ CTDB could not be consulted: \(error)")
        }
        guard let verification = outcome.verification else { return }
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
}
