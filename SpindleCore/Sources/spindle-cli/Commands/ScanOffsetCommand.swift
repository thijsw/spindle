import DiscDrive
import Foundation
import SpindleCore
import Verification

enum ScanOffsetCommand {
    static let help = """
      scan-offset <wavdir> [disk]
                        find the drive's read offset by testing an offset-0 rip
                        against the CUETools database at many candidate offsets
    """

    static func run(_ args: ArraySlice<String>) async throws {
        var scanner = ArgumentScanner(args)
        var wavDir: String?
        var disk: String?
        while let argument = scanner.next() {
            if wavDir == nil {
                wavDir = scanner.positional(argument, replacing: nil)
            } else {
                disk = scanner.positional(argument, replacing: disk)
            }
        }
        guard let wavDir else { fail("scan-offset needs a directory of trackNN.wav files") }

        let bsd = resolveDisc(disk)
        let (_, toc) = try await openDisc(bsdName: bsd)

        let wavURLs = wavFiles(in: wavDir)
        guard wavURLs.count == toc.audioTracks.count else {
            fail("Found \(wavURLs.count) WAVs but the disc has \(toc.audioTracks.count) audio tracks.")
        }

        print("Querying CTDB…")
        let entries = try await CTDBClient(userAgent: Spindle.userAgent).lookup(toc: toc)
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
        guard let best = candidates.first else { return }
        let signed = best.offset.formatted(.number.sign(strategy: .always()))
        if best.isFullMatch {
            print("\nDrive read offset: \(signed) samples.")
        } else {
            let failing = best.trackVerdicts.filter { !$0.value.isAccurate }.keys.sorted()
            print("\nBest candidate \(signed): tracks \(failing.map(String.init).joined(separator: ", ")) don't match any entry — damage, or a pressing difference at the disc edges.")
        }
        if let identity = DiscEnumerator.driveIdentity(forMediaBSDName: bsd) {
            print("Set this for \(identity.displayName) in Settings → Ripping.")
        }
    }
}
