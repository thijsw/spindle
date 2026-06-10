import DiscDrive
import Foundation
import RipEngine

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

@MainActor
func ripEngineTests() async {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("spindle-tests-\(ProcessInfo.processInfo.processIdentifier)")
    defer { try? FileManager.default.removeItem(at: dir) }

    Harness.suite("Checksums") {
        Harness.expect(
            CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926,
            "CRC32 matches the standard test vector"
        )

        // AccurateRip with a single full-value sample everywhere zero:
        // v1 = multiplier * value at the sample's 1-based index.
        var acc = ChecksumAccumulator(totalSamples: 10 * 588, isFirstTrack: false, isLastTrack: false)
        var audio = Data(count: 10 * 588 * 4)
        audio[4] = 0x01 // sample index 1 (0-based), little-endian value 1
        acc.update(audio)
        let sums = acc.finalize()
        Harness.expect(sums.accurateRipV1 == 2, "AR v1 multiplies value by 1-based sample index")
        Harness.expect(sums.accurateRipV2 == 2, "AR v2 equals v1 when no 32-bit overflow occurs")

        // First-track skip: a sample before 5*588-1 must not count.
        var first = ChecksumAccumulator(totalSamples: 10 * 588, isFirstTrack: true, isLastTrack: false)
        first.update(audio)
        Harness.expect(first.finalize().accurateRipV1 == 0, "first track skips the first 5×588−1 samples")

        // Streaming in odd-sized pieces must equal one-shot.
        var oneShot = ChecksumAccumulator(totalSamples: 10 * 588, isFirstTrack: false, isLastTrack: false)
        oneShot.update(audio)
        var pieces = ChecksumAccumulator(totalSamples: 10 * 588, isFirstTrack: false, isLastTrack: false)
        var rest = audio
        while !rest.isEmpty {
            let n = min(1337, rest.count)
            pieces.update(rest.prefix(n))
            rest = rest.dropFirst(n)
        }
        Harness.expect(oneShot.finalize() == pieces.finalize(), "streaming chunk sizes don't change checksums")
    }

    await Harness.asyncSuite("RipEngine") {
        let leadOut = 400
        let toc = makeTOC(trackSectors: [0 ..< 150, 150 ..< 400], leadOut: leadOut)

        // Burst rip, no offset: exact canonical bytes.
        do {
            let device = MockCDDevice(leadOut: leadOut)
            let ripper = DiscRipper(device: device, config: RipConfiguration(mode: .burst, chunkSectors: 25))
            let tracks = try await ripper.rip(toc: toc, to: dir.appendingPathComponent("burst"))
            Harness.expect(tracks.count == 2, "burst: ripped both tracks")
            Harness.expect(
                wavData(tracks[0].wavURL) == expectedAudio(trackSectors: 0 ..< 150, sampleOffset: 0, leadOut: leadOut),
                "burst: track 1 bytes exact"
            )
            Harness.expect(
                wavData(tracks[1].wavURL) == expectedAudio(trackSectors: 150 ..< 400, sampleOffset: 0, leadOut: leadOut),
                "burst: track 2 bytes exact"
            )
            let wav = (try? Data(contentsOf: tracks[0].wavURL)) ?? Data()
            Harness.expect(
                wav.prefix(4) == Data("RIFF".utf8) && wav.count == 44 + 150 * 2352,
                "burst: WAV header and size correct"
            )
        } catch {
            Harness.expect(false, "burst rip threw: \(error)")
        }

        // Positive offset: shifted stream with zero-fill at disc end.
        do {
            let device = MockCDDevice(leadOut: leadOut)
            let config = RipConfiguration(mode: .burst, sampleOffset: 102, chunkSectors: 25)
            let ripper = DiscRipper(device: device, config: config)
            let tracks = try await ripper.rip(toc: toc, to: dir.appendingPathComponent("offset+"))
            Harness.expect(
                wavData(tracks[0].wavURL) == expectedAudio(trackSectors: 0 ..< 150, sampleOffset: 102, leadOut: leadOut),
                "offset +102: track 1 shifted correctly"
            )
            Harness.expect(
                wavData(tracks[1].wavURL) == expectedAudio(trackSectors: 150 ..< 400, sampleOffset: 102, leadOut: leadOut),
                "offset +102: track 2 zero-fills past lead-out"
            )
        } catch {
            Harness.expect(false, "positive-offset rip threw: \(error)")
        }

        // Negative offset: zero-fill before sector 0.
        do {
            let device = MockCDDevice(leadOut: leadOut)
            let config = RipConfiguration(mode: .burst, sampleOffset: -30, chunkSectors: 25)
            let ripper = DiscRipper(device: device, config: config)
            let tracks = try await ripper.rip(toc: toc, to: dir.appendingPathComponent("offset-"))
            Harness.expect(
                wavData(tracks[0].wavURL) == expectedAudio(trackSectors: 0 ..< 150, sampleOffset: -30, leadOut: leadOut),
                "offset −30: track 1 zero-fills before disc start"
            )
        } catch {
            Harness.expect(false, "negative-offset rip threw: \(error)")
        }

        // Secure rip with C2: flaky sectors converge to canonical data.
        do {
            let device = MockCDDevice(leadOut: leadOut, flaky: [
                40: .init(badReads: 3, flagsC2: true),
                201: .init(badReads: 5, flagsC2: true),
            ])
            let config = RipConfiguration(mode: .secure(maxRetries: 16, agreeingPasses: 2), chunkSectors: 25)
            let ripper = DiscRipper(device: device, config: config)
            let tracks = try await ripper.rip(toc: toc, to: dir.appendingPathComponent("secure-c2"))
            Harness.expect(tracks[0].usedC2 && tracks[1].usedC2, "secure C2: C2 probe succeeded")
            Harness.expect(
                wavData(tracks[0].wavURL) == expectedAudio(trackSectors: 0 ..< 150, sampleOffset: 0, leadOut: leadOut),
                "secure C2: flaky sector 40 recovered exactly"
            )
            Harness.expect(
                wavData(tracks[1].wavURL) == expectedAudio(trackSectors: 150 ..< 400, sampleOffset: 0, leadOut: leadOut),
                "secure C2: flaky sector 201 recovered exactly"
            )
            Harness.expect(tracks[0].rereads > 0, "secure C2: re-reads recorded")
            Harness.expect(
                tracks.allSatisfy(\.unrecoverableSectors.isEmpty),
                "secure C2: no sectors left unrecovered"
            )
        } catch {
            Harness.expect(false, "secure C2 rip threw: \(error)")
        }

        // Secure rip without C2: compare-based detection still recovers.
        do {
            let device = MockCDDevice(leadOut: leadOut, supportsC2: false, flaky: [
                77: .init(badReads: 4, flagsC2: false),
            ])
            let config = RipConfiguration(mode: .secure(maxRetries: 16, agreeingPasses: 2), chunkSectors: 25)
            let ripper = DiscRipper(device: device, config: config)
            let tracks = try await ripper.rip(toc: toc, to: dir.appendingPathComponent("secure-cmp"))
            Harness.expect(!tracks[0].usedC2, "secure compare: C2 probe correctly failed")
            Harness.expect(
                wavData(tracks[0].wavURL) == expectedAudio(trackSectors: 0 ..< 150, sampleOffset: 0, leadOut: leadOut),
                "secure compare: flaky sector recovered without C2"
            )
        } catch {
            Harness.expect(false, "secure compare rip threw: \(error)")
        }

        // A sector that never settles is reported as unrecoverable.
        do {
            let device = MockCDDevice(leadOut: leadOut, flaky: [
                10: .init(badReads: 1000, flagsC2: true),
            ])
            let config = RipConfiguration(mode: .secure(maxRetries: 4, agreeingPasses: 2), chunkSectors: 25)
            let ripper = DiscRipper(device: device, config: config)
            let tracks = try await ripper.rip(toc: toc, to: dir.appendingPathComponent("unrecoverable"))
            Harness.expect(
                tracks[0].unrecoverableSectors == [10],
                "hopeless sector reported as unrecoverable"
            )
        } catch {
            Harness.expect(false, "unrecoverable-sector rip threw: \(error)")
        }

        // Rip determinism: two burst rips of a clean disc byte-identical.
        do {
            let device = MockCDDevice(leadOut: leadOut)
            let ripper = DiscRipper(device: device, config: RipConfiguration(mode: .burst))
            let a = try await ripper.rip(toc: toc, to: dir.appendingPathComponent("det-a"))
            let b = try await ripper.rip(toc: toc, to: dir.appendingPathComponent("det-b"))
            Harness.expect(
                a.map(\.checksums) == b.map(\.checksums),
                "two rips of a clean disc have identical checksums"
            )
        } catch {
            Harness.expect(false, "determinism rip threw: \(error)")
        }
    }
}
