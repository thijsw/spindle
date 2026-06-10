import AVFoundation
import CryptoKit
import Encoding
import Foundation
import Metadata
import Naming
import RipEngine
import Testing

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

/// Deterministic 16-bit stereo PCM (2 seconds), written as a staging WAV.
private func makeTestWAV(at url: URL) throws -> Data {
    let frames = 44100 * 2
    var pcm = Data(capacity: frames * 4)
    for i in 0 ..< frames {
        let left = Int16(truncatingIfNeeded: (i &* 37) ^ (i >> 3))
        let right = Int16(truncatingIfNeeded: (i &* 101) &+ 7)
        withUnsafeBytes(of: left.littleEndian) { pcm.append(contentsOf: $0) }
        withUnsafeBytes(of: right.littleEndian) { pcm.append(contentsOf: $0) }
    }
    let writer = try WAVWriter(url: url)
    try writer.append(pcm)
    try writer.finish()
    return pcm
}

/// Decodes any audio file back to interleaved 16-bit PCM bytes.
private func decodePCM(_ url: URL) throws -> Data {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65536) else {
        throw EncodingError.encodingFailed("buffer")
    }
    var pcm = Data()
    while file.framePosition < file.length {
        try file.read(into: buffer)
        if buffer.frameLength == 0 { break }
        if let channels = buffer.int16ChannelData {
            let bytes = Int(buffer.frameLength) * Int(file.processingFormat.channelCount) * 2
            pcm.append(Data(bytes: channels[0], count: bytes))
        }
    }
    return pcm
}

/// A tiny valid JPEG (red 1×1) for picture-block tests.
let tinyJPEG = Data(base64Encoded:
    "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB" +
    "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/2wBDAQEBAQEBAQEBAQEBAQEBAQEBAQEB" +
    "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/wAARCAABAAEDASIA" +
    "AhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/xAAUAQEA" +
    "AAAAAAAAAAAAAAAAAAAA/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEQMRAD8AVMH/2Q=="
)!

@Suite struct FLACEncodingTests {
    @Test func encodeTagAndRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wavURL = dir.appendingPathComponent("in.wav")
        let flacURL = dir.appendingPathComponent("out.flac")
        let pcm = try makeTestWAV(at: wavURL)

        let album = makeTestAlbum()
        let tags = TrackTags(album: album, track: album.tracks[0])
        let art = CoverArt(data: tinyJPEG, mimeType: "image/jpeg", source: .coverArtArchive)
        try await FLACEncoder().encode(wav: wavURL, to: flacURL, tags: tags, art: art)

        #expect(try decodePCM(flacURL) == pcm, "lossless round trip")

        let parsed = try FLACMetadata.parse(fileURL: flacURL)
        let comments = parsed.comments
        func value(_ key: String) -> String? { comments.first { $0.0 == key }?.1 }

        #expect(value("TITLE") == "First Song")
        #expect(value("ALBUMARTIST") == "Test Artist")
        #expect(value("TRACKNUMBER") == "1")
        #expect(value("TRACKTOTAL") == "2")
        #expect(value("MUSICBRAINZ_ALBUMID") == "11111111-aaaa-bbbb-cccc-000000000001")
        #expect(value("MUSICBRAINZ_TRACKID") == "77777777-aaaa-bbbb-cccc-000000000007")
        #expect(value("ISRC") == "NLA319700019")
        #expect(value("ORIGINALYEAR") == "1997")
        #expect(value("RELEASESTATUS") == "official")
        #expect(parsed.pictureData == tinyJPEG)

        let expectedMD5 = Data(Insecure.MD5.hash(data: pcm))
        #expect(parsed.streamInfo?.suffix(16) == expectedMD5, "STREAMINFO MD5 patched to PCM hash")

        // Rewriting again must replace tags and leave audio untouched.
        try FLACMetadata.rewrite(
            fileURL: flacURL,
            vorbisComments: [("TITLE", "Renamed")],
            picture: nil,
            pcmMD5: nil
        )
        let reparsed = try FLACMetadata.parse(fileURL: flacURL)
        #expect(reparsed.comments.contains { $0 == ("TITLE", "Renamed") })
        #expect(reparsed.pictureData == nil)
        #expect(try decodePCM(flacURL) == pcm, "audio frames untouched by rewrite")
    }
}

@Suite struct ALACEncodingTests {
    @Test func encodeTagAndRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wavURL = dir.appendingPathComponent("in.wav")
        let alacURL = dir.appendingPathComponent("out.m4a")
        let pcm = try makeTestWAV(at: wavURL)

        let album = makeTestAlbum()
        let tags = TrackTags(album: album, track: album.tracks[0])
        let art = CoverArt(data: tinyJPEG, mimeType: "image/jpeg", source: .coverArtArchive)
        try await ALACEncoder().encode(wav: wavURL, to: alacURL, tags: tags, art: art)

        #expect(try decodePCM(alacURL) == pcm, "lossless round trip")

        let asset = AVURLAsset(url: alacURL)
        let metadata = try await asset.load(.metadata)
        func string(_ identifier: AVMetadataIdentifier) async throws -> String? {
            guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first
            else { return nil }
            return try await item.load(.stringValue)
        }
        #expect(try await string(.iTunesMetadataSongName) == "First Song")
        #expect(try await string(.iTunesMetadataAlbum) == "Test Album")

        let artItem = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .iTunesMetadataCoverArt).first
        let artData = try await artItem?.load(.dataValue)
        #expect(artData == tinyJPEG, "cover art bytes intact")
    }
}

@Suite struct NamingTests {
    let album = makeTestAlbum()
    var track: ResolvedTrack { album.tracks[0] }

    @Test func standardTemplate() {
        #expect(
            NamingTemplate.standard.render(album: album, track: track)
                == "Test Artist/Test Album (1997)/01 - First Song"
        )
    }

    @Test func multiDiscVariants() {
        var multiDisc = album
        multiDisc.discNumber = 2
        multiDisc.discTotal = 2
        #expect(
            NamingTemplate.standard.render(album: multiDisc, track: track)
                == "Test Artist/Test Album (1997)/2-01 - First Song"
        )
        #expect(
            NamingTemplate.discFolders.render(album: multiDisc, track: track)
                == "Test Artist/Test Album (1997)/Disc 2/01 - First Song"
        )
    }

    @Test func conditionalGroupDropsWhenTokenEmpty() {
        var noYear = album
        noYear.date = nil
        #expect(
            NamingTemplate.standard.render(album: noYear, track: track)
                == "Test Artist/Test Album/01 - First Song"
        )
    }

    @Test func sanitization() {
        var nasty = album
        nasty.albumArtist = "AC/DC"
        nasty.album = "Back in Black: Live? *Deluxe*"
        var nastyTrack = track
        nastyTrack.title = "What\u{0007}ever... "
        #expect(
            NamingTemplate.standard.render(album: nasty, track: nastyTrack)
                == "AC-DC/Back in Black- Live- -Deluxe- (1997)/01 - What ever"
        )

        #expect(PathSanitizer.component("CON") == "CON_", "Windows reserved name escaped")
        #expect(PathSanitizer.component("...hidden") == "hidden", "leading dots stripped")
        #expect(PathSanitizer.component(String(repeating: "ü", count: 300)).utf8.count <= 240)

        let nfc = PathSanitizer.component("Cafe\u{0301}") // decomposed é
        #expect(nfc == "Café" && nfc.unicodeScalars.count == 4, "NFC normalization applied")
    }
}
