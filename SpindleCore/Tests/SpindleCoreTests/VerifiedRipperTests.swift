import DiscDrive
import Foundation
import RipEngine
import Testing
import Verification

/// RipVerifier backed by a fixed set of database entries (no network).
private struct StaticCTDBVerifier: RipVerifier {
    let entries: [CTDBEntry]

    func verify(
        toc: TOC, trackChecksums: [Int: TrackChecksums], ctdbDiscCRC32: UInt32?
    ) async throws -> VerificationResult {
        CTDBVerifier.match(
            entries: entries,
            audioTrackNumbers: toc.audioTracks.map(\.number),
            trackChecksums: trackChecksums,
            ctdbDiscCRC32: ctdbDiscCRC32
        )
    }
}

@Suite struct VerifiedRipperTests {
    let leadOut = 400
    var toc: TOC {
        TOC(
            tracks: [
                TOCTrack(number: 1, session: 1, startLBA: 0, isAudio: true, hasPreEmphasis: false),
                TOCTrack(number: 2, session: 1, startLBA: 150, isAudio: true, hasPreEmphasis: false),
            ],
            sessionLeadOuts: [1: leadOut],
            firstSession: 1,
            lastSession: 1
        )
    }

    /// CTDB entry whose track CRCs are those of the canonical (clean) audio.
    var canonicalEntry: CTDBEntry {
        let totalSamples = leadOut * 588
        let prefix = 2940
        let suffix = 2940 + totalSamples % 2940
        let windows = [
            prefix * 4 ..< 150 * 2352,
            150 * 2352 ..< (totalSamples - suffix) * 4,
        ]
        let crcs = windows.map { window in
            CRC32.checksum(Data(window.map { MockCDDevice.canonicalByte(at: $0) }))
        }
        return CTDBEntry(
            id: "canon", confidence: 42, discCRC32: 0,
            trackCRC32s: crcs, stride: 5880, hasParity: false, tocString: ""
        )
    }

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
        #expect(outcome.strategy.contains("fast pass"), "early exit reported")
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

    @Test func unknownDiscFallsBackToFullSecureRip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let device = MockCDDevice(leadOut: leadOut)
        let ripper = VerifiedRipper(
            device: device,
            configuration: RipConfiguration(mode: .secureDefault),
            verifier: StaticCTDBVerifier(entries: []) // disc not in the database
        )
        let outcome = try await ripper.rip(toc: toc, to: dir)

        #expect(outcome.reRippedTracks == [1, 2], "all tracks re-ripped securely")
        #expect(outcome.strategy.contains("not in CTDB"), "fallback reported")
        // Audio still byte-exact.
        let wav = try Data(contentsOf: dir.appendingPathComponent("track01.wav")).dropFirst(44)
        let expected = Data((0 ..< 150 * 2352).map { MockCDDevice.canonicalByte(at: $0) })
        #expect(wav == expected)
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
}
