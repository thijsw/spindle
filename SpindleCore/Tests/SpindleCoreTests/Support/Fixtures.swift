import DiscDrive
import Foundation
import Metadata
import RipEngine
import Testing
import Verification

// Fixtures shared across suites. Kept here so no test file depends on
// helpers that happen to live in another suite's file.

/// Single-session all-audio TOC from sector ranges.
func makeTOC(trackSectors: [Range<Int>], leadOut: Int) -> TOC {
    TOC(
        tracks: trackSectors.enumerated().map { i, range in
            TOCTrack(number: i + 1, session: 1, startLBA: range.lowerBound, isAudio: true, hasPreEmphasis: false)
        },
        sessionLeadOuts: [1: leadOut],
        firstSession: 1,
        lastSession: 1
    )
}

/// Expected corrected audio for a track ripped from `MockCDDevice`: the
/// virtual disc byte stream (canonical bytes inside [0, leadOut), zeros
/// outside) shifted by the sample offset.
func expectedAudio(trackSectors: Range<Int>, sampleOffset: Int, leadOut: Int) -> Data {
    let start = trackSectors.lowerBound * 2352 + sampleOffset * 4
    let end = trackSectors.upperBound * 2352 + sampleOffset * 4
    let readable = 0 ..< (leadOut * 2352)
    return Data((start ..< end).map { pos in
        readable.contains(pos) ? MockCDDevice.canonicalByte(at: pos) : 0
    })
}

/// Canonical mock-disc bytes over an absolute byte range.
func canonicalBytes(_ range: Range<Int>) -> Data {
    Data(range.map { MockCDDevice.canonicalByte(at: $0) })
}

/// Audio payload of a staged WAV (everything after the 44-byte header).
func wavData(_ url: URL) -> Data {
    let data = (try? Data(contentsOf: url)) ?? Data()
    return data.count > WAVWriter.headerSize ? data.subdata(in: WAVWriter.headerSize ..< data.count) : Data()
}

/// A CTDB entry whose track CRCs are those of the canonical mock audio for
/// `toc`, so a clean rip verifies against it.
func canonicalCTDBEntry(for toc: TOC, confidence: Int = 42) -> CTDBEntry {
    let crcs = CTDBWindow.trackWindows(for: toc).map { window in
        CRC32.checksum(canonicalBytes(window.samples.lowerBound * 4 ..< window.samples.upperBound * 4))
    }
    return CTDBEntry(id: "canon", confidence: confidence, discCRC32: 0, trackCRC32s: crcs, hasParity: false)
}

/// RipVerifier backed by a fixed set of database entries (no network).
/// `error` makes every lookup fail instead, like a network outage.
struct StaticCTDBVerifier: RipVerifier {
    var entries: [CTDBEntry] = []
    var error: (any Error)?

    func verify(
        toc: TOC, trackChecksums: [Int: TrackChecksums], ctdbDiscCRC32: UInt32?
    ) async throws -> VerificationResult {
        if let error { throw error }
        return CTDBVerifier.match(
            entries: entries,
            audioTrackNumbers: toc.audioTracks.map(\.number),
            trackChecksums: trackChecksums,
            ctdbDiscCRC32: ctdbDiscCRC32
        )
    }
}

/// A fully tagged two-track album for encoder and naming tests.
func makeTestAlbum() -> ResolvedAlbum {
    ResolvedAlbum(
        album: "Test Album",
        albumArtist: "Test Artist",
        albumArtistSort: "Artist, Test",
        albumArtistMBIDs: ["33333333-aaaa-bbbb-cccc-000000000003"],
        releaseMBID: "11111111-aaaa-bbbb-cccc-000000000001",
        releaseGroupMBID: "22222222-aaaa-bbbb-cccc-000000000002",
        discID: "xUp1F2NkfP8s8jaeFn_Av3jNEI4-",
        date: "1997-09-23",
        originalDate: "1997-09-22",
        country: "NL",
        label: "Test Records",
        catalogNumber: "CAT-001",
        barcode: "724385522123",
        status: "Official",
        tracks: [
            ResolvedTrack(
                position: 1,
                title: "First Song",
                artist: "Test Artist",
                artistMBIDs: ["33333333-aaaa-bbbb-cccc-000000000003"],
                recordingMBID: "77777777-aaaa-bbbb-cccc-000000000007",
                trackMBID: "66666666-aaaa-bbbb-cccc-000000000006",
                isrc: "NLA319700019"
            ),
            ResolvedTrack(position: 2, title: "Second Song", artist: "Test Artist"),
        ]
    )
}

/// Runs `body` with a fresh scratch directory that is removed afterwards.
func withTempDir<T>(_ body: (URL) async throws -> T) async throws -> T {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    return try await body(dir)
}
