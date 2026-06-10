import DiscDrive
import Foundation
import RipEngine
import Testing

/// Expected corrected audio for a track: the virtual disc byte stream
/// (canonical bytes inside [0, leadOut), zeros outside) shifted by the offset.
private func expectedAudio(trackSectors: Range<Int>, sampleOffset: Int, leadOut: Int) -> Data {
    let start = trackSectors.lowerBound * 2352 + sampleOffset * 4
    let end = trackSectors.upperBound * 2352 + sampleOffset * 4
    let readable = 0 ..< (leadOut * 2352)
    return Data((start ..< end).map { pos in
        readable.contains(pos) ? MockCDDevice.canonicalByte(at: pos) : 0
    })
}

private func makeTOC(trackSectors: [Range<Int>], leadOut: Int) -> TOC {
    TOC(
        tracks: trackSectors.enumerated().map { i, range in
            TOCTrack(number: i + 1, session: 1, startLBA: range.lowerBound, isAudio: true, hasPreEmphasis: false)
        },
        sessionLeadOuts: [1: leadOut],
        firstSession: 1,
        lastSession: 1
    )
}

private func wavData(_ url: URL) -> Data {
    let data = (try? Data(contentsOf: url)) ?? Data()
    return data.count > 44 ? data.subdata(in: 44 ..< data.count) : Data()
}

@Suite struct ChecksumTests {
    @Test func crc32MatchesStandardVector() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func accurateRipSemantics() {
        // A single non-zero sample: v1 = multiplier × value at 1-based index.
        var audio = Data(count: 10 * 588 * 4)
        audio[4] = 0x01 // sample index 1 (0-based), little-endian value 1

        var acc = ChecksumAccumulator(totalSamples: 10 * 588, isFirstTrack: false, isLastTrack: false)
        acc.update(audio)
        let sums = acc.finalize()
        #expect(sums.accurateRipV1 == 2, "AR v1 multiplies value by 1-based sample index")
        #expect(sums.accurateRipV2 == 2, "AR v2 equals v1 when no 32-bit overflow occurs")

        var first = ChecksumAccumulator(totalSamples: 10 * 588, isFirstTrack: true, isLastTrack: false)
        first.update(audio)
        #expect(first.finalize().accurateRipV1 == 0, "first track skips the first 5×588−1 samples")
    }

    @Test func streamingChunkSizesDoNotChangeChecksums() {
        var audio = Data(count: 10 * 588 * 4)
        audio[4] = 0x01

        var oneShot = ChecksumAccumulator(totalSamples: 10 * 588, isFirstTrack: false, isLastTrack: false)
        oneShot.update(audio)

        var pieces = ChecksumAccumulator(totalSamples: 10 * 588, isFirstTrack: false, isLastTrack: false)
        var rest = audio
        while !rest.isEmpty {
            let n = min(1337, rest.count)
            pieces.update(rest.prefix(n))
            rest = rest.dropFirst(n)
        }
        #expect(oneShot.finalize() == pieces.finalize())
    }
}

@Suite struct RipEngineTests {
    let leadOut = 400
    var toc: TOC { makeTOC(trackSectors: [0 ..< 150, 150 ..< 400], leadOut: leadOut) }

    @Test func burstRipIsExact() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let device = MockCDDevice(leadOut: leadOut)
        let ripper = DiscRipper(device: device, config: RipConfiguration(mode: .burst, chunkSectors: 25))
        let tracks = try await ripper.rip(toc: toc, to: dir)

        #expect(tracks.count == 2)
        #expect(wavData(tracks[0].wavURL) == expectedAudio(trackSectors: 0 ..< 150, sampleOffset: 0, leadOut: leadOut))
        #expect(wavData(tracks[1].wavURL) == expectedAudio(trackSectors: 150 ..< 400, sampleOffset: 0, leadOut: leadOut))

        let wav = try Data(contentsOf: tracks[0].wavURL)
        #expect(wav.prefix(4) == Data("RIFF".utf8))
        #expect(wav.count == 44 + 150 * 2352)
    }

    @Test func positiveOffsetShiftsAndZeroFillsAtLeadOut() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let device = MockCDDevice(leadOut: leadOut)
        let config = RipConfiguration(mode: .burst, sampleOffset: 102, chunkSectors: 25)
        let tracks = try await DiscRipper(device: device, config: config).rip(toc: toc, to: dir)

        #expect(wavData(tracks[0].wavURL) == expectedAudio(trackSectors: 0 ..< 150, sampleOffset: 102, leadOut: leadOut))
        #expect(wavData(tracks[1].wavURL) == expectedAudio(trackSectors: 150 ..< 400, sampleOffset: 102, leadOut: leadOut))
    }

    @Test func negativeOffsetZeroFillsBeforeDiscStart() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let device = MockCDDevice(leadOut: leadOut)
        let config = RipConfiguration(mode: .burst, sampleOffset: -30, chunkSectors: 25)
        let tracks = try await DiscRipper(device: device, config: config).rip(toc: toc, to: dir)

        #expect(wavData(tracks[0].wavURL) == expectedAudio(trackSectors: 0 ..< 150, sampleOffset: -30, leadOut: leadOut))
    }

    @Test func secureRipWithC2RecoversFlakySectors() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let device = MockCDDevice(leadOut: leadOut, flaky: [
            40: .init(badReads: 3, flagsC2: true),
            201: .init(badReads: 5, flagsC2: true),
        ])
        let config = RipConfiguration(mode: .secure(maxRetries: 16, agreeingPasses: 2), chunkSectors: 25)
        let tracks = try await DiscRipper(device: device, config: config).rip(toc: toc, to: dir)

        #expect(tracks[0].usedC2 && tracks[1].usedC2, "C2 probe succeeded")
        #expect(wavData(tracks[0].wavURL) == expectedAudio(trackSectors: 0 ..< 150, sampleOffset: 0, leadOut: leadOut))
        #expect(wavData(tracks[1].wavURL) == expectedAudio(trackSectors: 150 ..< 400, sampleOffset: 0, leadOut: leadOut))
        #expect(tracks[0].rereads > 0)
        let allRecovered = tracks.allSatisfy { $0.unrecoverableSectors.isEmpty }
        #expect(allRecovered)
    }

    @Test func secureRipWithoutC2FallsBackToComparison() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let device = MockCDDevice(leadOut: leadOut, supportsC2: false, flaky: [
            77: .init(badReads: 4, flagsC2: false),
        ])
        let config = RipConfiguration(mode: .secure(maxRetries: 16, agreeingPasses: 2), chunkSectors: 25)
        let tracks = try await DiscRipper(device: device, config: config).rip(toc: toc, to: dir)

        #expect(!tracks[0].usedC2, "C2 probe correctly failed")
        #expect(wavData(tracks[0].wavURL) == expectedAudio(trackSectors: 0 ..< 150, sampleOffset: 0, leadOut: leadOut))
    }

    @Test func hopelessSectorReportedAsUnrecoverable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let device = MockCDDevice(leadOut: leadOut, flaky: [
            10: .init(badReads: 1000, flagsC2: true),
        ])
        let config = RipConfiguration(mode: .secure(maxRetries: 4, agreeingPasses: 2), chunkSectors: 25)
        let tracks = try await DiscRipper(device: device, config: config).rip(toc: toc, to: dir)

        #expect(tracks[0].unrecoverableSectors == [10])
    }

    @Test func hardReadErrorsAreBisectedNotFatal() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Sector 90 always fails with EIO: chunks containing it must be
        // bisected so every other sector still rips exactly, the bad sector
        // is zero-filled, and the rip completes instead of aborting.
        let device = MockCDDevice(leadOut: leadOut, errorSectors: [90])
        let config = RipConfiguration(mode: .secure(maxRetries: 4, agreeingPasses: 2), chunkSectors: 25)
        let tracks = try await DiscRipper(device: device, config: config).rip(toc: toc, to: dir)

        #expect(tracks[0].unrecoverableSectors == [90], "damaged sector reported")

        var expected = expectedAudio(trackSectors: 0 ..< 150, sampleOffset: 0, leadOut: leadOut)
        expected.replaceSubrange(90 * 2352 ..< 91 * 2352, with: Data(count: 2352))
        #expect(wavData(tracks[0].wavURL) == expected, "all healthy sectors exact, bad sector zero-filled")
        #expect(
            wavData(tracks[1].wavURL) == expectedAudio(trackSectors: 150 ..< 400, sampleOffset: 0, leadOut: leadOut),
            "other track unaffected"
        )
    }

    @Test func longDamageRunIsMappedWithBoundedContacts() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A 240-sector scratch spanning three chunks and the track boundary.
        // Naive per-sector probing would cost one failing read per damaged
        // sector (1–2 minutes each on real drives); damage-run mapping plus
        // continuation mode must cross it in a bounded number of contacts,
        // zero-fill it sector-exactly, and never touch it again in later
        // passes.
        let damage = 90 ..< 330
        let device = MockCDDevice(leadOut: leadOut, errorSectors: Set(damage))
        let config = RipConfiguration(mode: .secure(maxRetries: 4, agreeingPasses: 2), chunkSectors: 150)
        let result = try await DiscRipper(device: device, config: config).ripDisc(toc: toc, to: dir)

        let allBad = result.tracks.flatMap(\.unrecoverableSectors).sorted()
        #expect(allBad == Array(damage), "exactly the damaged run reported, boundaries sector-exact")

        var expected1 = expectedAudio(trackSectors: 0 ..< 150, sampleOffset: 0, leadOut: leadOut)
        expected1.replaceSubrange(90 * 2352 ..< 150 * 2352, with: Data(count: 60 * 2352))
        #expect(wavData(result.tracks[0].wavURL) == expected1, "track 1: healthy sectors exact, damage zeroed")

        var expected2 = expectedAudio(trackSectors: 150 ..< 400, sampleOffset: 0, leadOut: leadOut)
        expected2.replaceSubrange(0 ..< 180 * 2352, with: Data(count: 180 * 2352))
        #expect(wavData(result.tracks[1].wavURL) == expected2, "track 2: damage zeroed, rest exact")

        // Contact budget: two compare passes over 400 sectors with a
        // 150-sector run. Naive per-sector mapping would need 150+ failing
        // contacts; run mapping stays logarithmic.
        let reads = await device.readCount
        #expect(reads < 200, "bounded device contacts (got \(reads))")
    }

    @Test func lyingC2IsDetectedAndRetiredMidRip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The drive's C2 looks healthy at the probe (sectors 0..32) but
        // flags every sector from 100 on, despite perfect audio — the Apple
        // SuperDrive failure mode. The engine must catch the implausible
        // flag rate, restart the track in compare mode, and stop using C2
        // for the rest of the disc.
        let device = MockCDDevice(leadOut: leadOut, c2LiesAfterSector: 100)
        let config = RipConfiguration(mode: .secure(maxRetries: 4, agreeingPasses: 2), chunkSectors: 150)
        let result = try await DiscRipper(device: device, config: config)
            .ripDisc(toc: toc, to: dir)

        #expect(result.c2Distrusted, "the lie was caught")
        #expect(!result.usedC2, "C2 retired for the rest of the disc")
        #expect(result.tracks[0].c2Distrusted, "track 1 was restarted in compare mode")
        #expect(!result.tracks[1].usedC2, "track 2 never used C2")
        #expect(
            result.tracks.allSatisfy { $0.unrecoverableSectors.isEmpty },
            "no false damage reports from lie-flagged sectors"
        )
        #expect(
            wavData(result.tracks[0].wavURL) == expectedAudio(trackSectors: 0 ..< 150, sampleOffset: 0, leadOut: leadOut),
            "track 1 audio exact despite the lying C2"
        )
        #expect(
            wavData(result.tracks[1].wavURL) == expectedAudio(trackSectors: 150 ..< 400, sampleOffset: 0, leadOut: leadOut),
            "track 2 audio exact"
        )
    }

    @Test func disallowedC2IsNeverProbed() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // With allowC2 off, even a flag storm from sector 0 is irrelevant —
        // the C2 path must never engage.
        let device = MockCDDevice(leadOut: leadOut, c2LiesAfterSector: 0)
        var config = RipConfiguration(mode: .secure(maxRetries: 4, agreeingPasses: 2))
        config.allowC2 = false
        let result = try await DiscRipper(device: device, config: config)
            .ripDisc(toc: toc, to: dir)

        #expect(!result.usedC2)
        #expect(!result.c2Distrusted, "nothing to distrust — C2 was never consulted")
        #expect(
            wavData(result.tracks[0].wavURL) == expectedAudio(trackSectors: 0 ..< 150, sampleOffset: 0, leadOut: leadOut)
        )
    }

    @Test func hopelessTrackIsAbandonedWithinItsTimeBudget() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Track 1's tail is a crawl: one read touching it blocks for 6 s
        // (simulating the drive's internal retry storm), blowing the 4 s
        // budget at the next checkpoint. Track 2 starts on clean ground and
        // finishes orders of magnitude inside the budget even in parallel
        // debug-build test runs.
        // Tiny track 2 keeps its wall time orders of magnitude inside the
        // budget even under parallel debug-build test load.
        let smallTOC = makeTOC(trackSectors: [0 ..< 150, 150 ..< 175], leadOut: 175)
        let device = MockCDDevice(
            leadOut: 175,
            slowSectors: Set(60 ..< 150),
            slowReadDelay: .seconds(6)
        )
        var config = RipConfiguration(mode: .burst, chunkSectors: 25)
        config.trackTimeLimit = .seconds(4)
        let result = try await DiscRipper(device: device, config: config).ripDisc(toc: smallTOC, to: dir)

        #expect(result.failedTracks == [1], "track 1 abandoned")
        #expect(result.tracks.map(\.trackNumber) == [2], "track 2 still ripped")
        #expect(
            !FileManager.default.fileExists(atPath: dir.appendingPathComponent("track01.wav").path),
            "partial WAV of the abandoned track removed"
        )
        #expect(
            wavData(result.tracks[0].wavURL) == expectedAudio(trackSectors: 150 ..< 175, sampleOffset: 0, leadOut: 175),
            "track 2 byte-exact"
        )
        #expect(!result.isCompleteDisc, "disc marked incomplete")
    }

    @Test func cleanDiscRipsAreDeterministic() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let device = MockCDDevice(leadOut: leadOut)
        let ripper = DiscRipper(device: device, config: RipConfiguration(mode: .burst))
        let a = try await ripper.rip(toc: toc, to: dir.appendingPathComponent("a"))
        let b = try await ripper.rip(toc: toc, to: dir.appendingPathComponent("b"))
        #expect(a.map(\.checksums) == b.map(\.checksums))
    }
}
