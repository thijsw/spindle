import AVFoundation
import CryptoKit
import Encoding
import Foundation
import Metadata
import Naming
import RipEngine

private func makeTestAlbum() -> ResolvedAlbum {
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
        // Two distinct, fully deterministic waveforms.
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
private let tinyJPEG = Data(base64Encoded:
    "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB" +
    "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/2wBDAQEBAQEBAQEBAQEBAQEBAQEBAQEB" +
    "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/wAARCAABAAEDASIA" +
    "AhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/xAAUAQEA" +
    "AAAAAAAAAAAAAAAAAAAA/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEQMRAD8AVMH/2Q=="
)!

@MainActor
func encodingTests() async {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("spindle-encoding-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let album = makeTestAlbum()
    let tags = TrackTags(album: album, track: album.tracks[0])

    await Harness.asyncSuite("FLAC encoding") {
        let wavURL = dir.appendingPathComponent("in.wav")
        let flacURL = dir.appendingPathComponent("out.flac")
        guard let pcm = try? makeTestWAV(at: wavURL) else {
            Harness.expect(false, "test WAV written")
            return
        }

        do {
            let art = CoverArt(data: tinyJPEG, mimeType: "image/jpeg", source: .coverArtArchive)
            try await FLACEncoder().encode(wav: wavURL, to: flacURL, tags: tags, art: art)
        } catch {
            Harness.expect(false, "FLAC encode threw: \(error)")
            return
        }

        Harness.expect(
            (try? decodePCM(flacURL)) == pcm,
            "FLAC decodes back to bit-identical PCM (lossless round trip)"
        )

        do {
            let parsed = try FLACMetadata.parse(fileURL: flacURL)
            let comments = parsed.comments
            func value(_ key: String) -> String? {
                comments.first { $0.0 == key }?.1
            }
            Harness.expect(value("TITLE") == "First Song", "TITLE comment")
            Harness.expect(value("ALBUMARTIST") == "Test Artist", "ALBUMARTIST comment")
            Harness.expect(value("TRACKNUMBER") == "1" && value("TRACKTOTAL") == "2", "track numbering")
            Harness.expect(value("MUSICBRAINZ_ALBUMID") == "11111111-aaaa-bbbb-cccc-000000000001", "MB release ID")
            Harness.expect(value("MUSICBRAINZ_TRACKID") == "77777777-aaaa-bbbb-cccc-000000000007", "MB recording ID")
            Harness.expect(value("ISRC") == "NLA319700019", "ISRC comment")
            Harness.expect(value("ORIGINALYEAR") == "1997", "original year derived")
            Harness.expect(value("RELEASESTATUS") == "official", "release status lowercased")
            Harness.expect(parsed.pictureData == tinyJPEG, "embedded picture bytes intact")

            let expectedMD5 = Data(Insecure.MD5.hash(data: pcm))
            Harness.expect(
                parsed.streamInfo?.suffix(16) == expectedMD5,
                "STREAMINFO MD5 patched to PCM hash"
            )
        } catch {
            Harness.expect(false, "FLAC metadata parse threw: \(error)")
        }

        // Rewriting must be idempotent-safe: tags can be rewritten again.
        do {
            try FLACMetadata.rewrite(
                fileURL: flacURL,
                vorbisComments: [("TITLE", "Renamed")],
                picture: nil,
                pcmMD5: nil
            )
            let reparsed = try FLACMetadata.parse(fileURL: flacURL)
            Harness.expect(
                reparsed.comments.contains { $0 == ("TITLE", "Renamed") } && reparsed.pictureData == nil,
                "second rewrite replaces tags and drops picture"
            )
            Harness.expect(
                (try? decodePCM(flacURL)) == pcm,
                "audio frames untouched by rewrite"
            )
        } catch {
            Harness.expect(false, "FLAC rewrite threw: \(error)")
        }
    }

    await Harness.asyncSuite("ALAC encoding") {
        let wavURL = dir.appendingPathComponent("in2.wav")
        let alacURL = dir.appendingPathComponent("out.m4a")
        guard let pcm = try? makeTestWAV(at: wavURL) else {
            Harness.expect(false, "test WAV written")
            return
        }

        do {
            let art = CoverArt(data: tinyJPEG, mimeType: "image/jpeg", source: .coverArtArchive)
            try await ALACEncoder().encode(wav: wavURL, to: alacURL, tags: tags, art: art)
        } catch {
            Harness.expect(false, "ALAC encode threw: \(error)")
            return
        }

        Harness.expect(
            (try? decodePCM(alacURL)) == pcm,
            "ALAC decodes back to bit-identical PCM (lossless round trip)"
        )

        let asset = AVURLAsset(url: alacURL)
        if let metadata = try? await asset.load(.metadata) {
            @MainActor func string(_ identifier: AVMetadataIdentifier) async -> String? {
                guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first
                else { return nil }
                return try? await item.load(.stringValue)
            }
            let title = await string(.iTunesMetadataSongName)
            let albumName = await string(.iTunesMetadataAlbum)
            Harness.expect(title == "First Song", "M4A title tag")
            Harness.expect(albumName == "Test Album", "M4A album tag")
            let artItem = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .iTunesMetadataCoverArt).first
            let artData: Data? = if let artItem { try? await artItem.load(.dataValue) ?? nil } else { nil }
            Harness.expect(artData == tinyJPEG, "M4A cover art bytes intact")
        } else {
            Harness.expect(false, "M4A metadata loads")
        }
    }

    Harness.suite("Naming") {
        let track = album.tracks[0]
        Harness.expect(
            NamingTemplate.standard.render(album: album, track: track)
                == "Test Artist/Test Album (1997)/01 - First Song",
            "standard template renders"
        )

        var multiDisc = album
        multiDisc.discNumber = 2
        multiDisc.discTotal = 2
        Harness.expect(
            NamingTemplate.standard.render(album: multiDisc, track: track)
                == "Test Artist/Test Album (1997)/2-01 - First Song",
            "multi-disc prefix appears only when disctotal > 1"
        )
        Harness.expect(
            NamingTemplate.discFolders.render(album: multiDisc, track: track)
                == "Test Artist/Test Album (1997)/Disc 2/01 - First Song",
            "disc-folder template variant"
        )

        var noYear = album
        noYear.date = nil
        Harness.expect(
            NamingTemplate.standard.render(album: noYear, track: track)
                == "Test Artist/Test Album/01 - First Song",
            "year group dropped when date missing"
        )

        var nasty = album
        nasty.albumArtist = "AC/DC"
        nasty.album = "Back in Black: Live? *Deluxe*"
        var nastyTrack = track
        nastyTrack.title = "What\u{0007}ever... "
        let rendered = NamingTemplate.standard.render(album: nasty, track: nastyTrack)
        Harness.expect(
            rendered == "AC-DC/Back in Black- Live- -Deluxe- (1997)/01 - What ever",
            "slashes, colons, control chars and trailing dots sanitized"
        )

        Harness.expect(PathSanitizer.component("CON") == "CON_", "Windows reserved name escaped")
        Harness.expect(PathSanitizer.component("...hidden") == "hidden", "leading dots stripped")
        Harness.expect(
            PathSanitizer.component(String(repeating: "ü", count: 300)).utf8.count <= 240,
            "length capped at 240 UTF-8 bytes"
        )
        let nfc = PathSanitizer.component("Cafe\u{0301}") // decomposed é
        Harness.expect(nfc == "Café" && nfc.unicodeScalars.count == 4, "NFC normalization applied")
    }
}
