import DiscDrive
import Foundation
@testable import RipEngine
import Testing
import Verification

@Suite struct VerifiedRipperTests {
    let leadOut = 400
    var toc: TOC { makeTOC(trackSectors: [0 ..< 150, 150 ..< 400], leadOut: leadOut) }
    /// CTDB entry whose track CRCs are those of the canonical (clean) audio.
    var canonicalEntry: CTDBEntry { canonicalCTDBEntry(for: toc) }

    @Test func cleanDiscVerifiesInTheFastPassWithoutSecureMachinery() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let device = MockCDDevice(leadOut: leadOut)
        let ripper = VerifiedRipper(
            device: device,
            configuration: RipConfiguration(mode: .secureDefault),
            verifier: StaticCTDBVerifier(entries: [canonicalEntry])
        )
        let outcome = try await ripper.rip(toc: toc, to: dir)

        #expect(outcome.reRippedTracks.isEmpty, "no secure re-rips needed")
        #expect(outcome.summary.contains("verified"), "verification reported")
        let verdicts = outcome.verification?.trackVerdicts
        #expect(verdicts?[1] == .accuratelyRipped(confidence: 42))
        #expect(verdicts?[2] == .accuratelyRipped(confidence: 42))
        // Burst-only: both tracks read once, no per-sector retries.
        let totalReads = await device.readCount
        #expect(totalReads <= 8, "burst pass uses only chunked reads (got \(totalReads))")
    }

    @Test func corruptedFastPassTriggersTargetedSecureReRip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // One bad read at sector 200 (inside track 2): the burst pass picks
        // up garbage there, the database flags track 2, and only track 2
        // gets the secure treatment.
        let device = MockCDDevice(leadOut: leadOut, flaky: [
            200: .init(badReads: 1, flagsC2: true),
        ])
        let ripper = VerifiedRipper(
            device: device,
            configuration: RipConfiguration(mode: .secureDefault),
            verifier: StaticCTDBVerifier(entries: [canonicalEntry])
        )
        let outcome = try await ripper.rip(toc: toc, to: dir)

        #expect(outcome.reRippedTracks == [2], "only the failing track is re-ripped")
        let verdicts = outcome.verification?.trackVerdicts
        #expect(verdicts?[1] == .accuratelyRipped(confidence: 42), "track 1 verified from fast pass")
        #expect(verdicts?[2] == .accuratelyRipped(confidence: 42), "track 2 verified after re-rip")

        // The patched WAV must be the canonical audio.
        let wav = try Data(contentsOf: dir.appendingPathComponent("track02.wav")).dropFirst(44)
        let expected = Data((150 * 2352 ..< 400 * 2352).map { MockCDDevice.canonicalByte(at: $0) })
        #expect(wav == expected, "re-ripped track is byte-exact")
    }

    @Test func unknownDiscWithCleanReadIsAcceptedWithoutReRip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Disc not in CTDB (or a different master): a clean burst read is
        // trusted — re-reading identical clean sectors would change nothing,
        // so no track is re-ripped. (This is the Enhanced-CD case.)
        let device = MockCDDevice(leadOut: leadOut)
        let ripper = VerifiedRipper(
            device: device,
            configuration: RipConfiguration(mode: .secureDefault),
            verifier: StaticCTDBVerifier(entries: [])
        )
        let outcome = try await ripper.rip(toc: toc, to: dir)

        #expect(outcome.reRippedTracks.isEmpty, "clean unknown disc not re-ripped")
        #expect(outcome.summary.contains("read clean"), "trust-clean-read reported")
        let wav = try Data(contentsOf: dir.appendingPathComponent("track01.wav")).dropFirst(44)
        let expected = Data((0 ..< 150 * 2352).map { MockCDDevice.canonicalByte(at: $0) })
        #expect(wav == expected)
    }

    @Test func unknownDiscReRipsOnlyTracksWithReadErrors() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Disc not in CTDB, but sector 200 (track 2) is unreadable (EIO):
        // a clean read can't be assumed there, so only track 2 is re-ripped.
        let device = MockCDDevice(leadOut: leadOut, errorSectors: [200])
        let ripper = VerifiedRipper(
            device: device,
            configuration: RipConfiguration(mode: .secureDefault),
            verifier: StaticCTDBVerifier(entries: [])
        )
        let outcome = try await ripper.rip(toc: toc, to: dir)

        #expect(outcome.reRippedTracks == [2], "only the read-error track is re-ripped")
        // Track 1 (clean) is the untouched burst read.
        let wav1 = try Data(contentsOf: dir.appendingPathComponent("track01.wav")).dropFirst(44)
        #expect(wav1 == Data((0 ..< 150 * 2352).map { MockCDDevice.canonicalByte(at: $0) }))
    }

    @Test func fastModeVerifiesButNeverReRips() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let device = MockCDDevice(leadOut: leadOut, flaky: [
            200: .init(badReads: 1, flagsC2: false),
        ])
        let ripper = VerifiedRipper(
            device: device,
            configuration: RipConfiguration(mode: .burst),
            verifier: StaticCTDBVerifier(entries: [canonicalEntry])
        )
        let outcome = try await ripper.rip(toc: toc, to: dir)

        #expect(outcome.reRippedTracks.isEmpty, "fast mode reports but doesn't fix")
        #expect(outcome.verification?.trackVerdicts[2] == .differs(bestConfidence: 42))
    }

    /// A verifier outage must be reported as such, not as "not in CTDB":
    /// the clean read is still trusted, the log says why it is unverified.
    @Test func verifierFailureIsReportedNotDisguised() async throws {
        try await withTempDir { dir in
            struct Outage: Error {}
            let ripper = VerifiedRipper(
                device: MockCDDevice(leadOut: leadOut),
                configuration: RipConfiguration(mode: .secureDefault),
                verifier: StaticCTDBVerifier(error: Outage())
            )
            let outcome = try await ripper.rip(toc: toc, to: dir)
            #expect(outcome.verification == nil)
            #expect(outcome.verificationError?.contains("Outage") == true)
            #expect(outcome.strategy == .fastTrusted, "clean read still trusted")
            #expect(outcome.summary.contains("CTDB unavailable"))
            #expect(outcome.reRippedTracks.isEmpty)
        }
    }

    @Test func reRipPolicyIsPure() {
        func track(_ n: Int, unrecoverable: [Int] = []) -> RippedTrack {
            RippedTrack(
                trackNumber: n, wavURL: URL(fileURLWithPath: "/dev/null"),
                checksums: TrackChecksums(crc32: 0, accurateRipV1: 0, accurateRipV2: 0, ctdbCRC32: 0),
                rereads: 0, unrecoverableSectors: unrecoverable, usedC2: false
            )
        }
        let firstPass = DiscRipper.DiscRipResult(
            tracks: [track(1), track(2, unrecoverable: [200]), track(4)],
            ctdbDiscCRC32: 0, isCompleteDisc: false, usedC2: false, c2Unreliable: false,
            failedTracks: [3], tunedChunkSectors: 150
        )
        let entry = CTDBEntry(id: "e", confidence: 5, discCRC32: 0, trackCRC32s: [], hasParity: false)

        // Some tracks verified: only the ones that DIFFER are re-ripped.
        let partlyVerified = VerificationResult(
            entries: [entry],
            trackVerdicts: [1: .accuratelyRipped(confidence: 5), 2: .accuratelyRipped(confidence: 5), 3: .differs(bestConfidence: 5), 4: .differs(bestConfidence: 5)],
            discMatch: nil
        )
        #expect(
            VerifiedRipper.tracksToReRip(firstPass: firstPass, verification: partlyVerified) == [4],
            "track 4 differs; track 3 differs too but already failed its budget"
        )

        // Nothing verified (disc unknown): re-rip only tracks with read errors.
        let unknown = VerificationResult(entries: [], trackVerdicts: [1: .notInDatabase, 2: .notInDatabase, 4: .notInDatabase], discMatch: nil)
        #expect(VerifiedRipper.tracksToReRip(firstPass: firstPass, verification: unknown) == [2])
        #expect(VerifiedRipper.tracksToReRip(firstPass: firstPass, verification: nil) == [2])
    }
}
