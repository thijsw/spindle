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
