import AVFoundation
import CryptoKit
@testable import Encoding
import Foundation
import Metadata
import Naming
import RipEngine
import Testing

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

@Suite struct M4AEncodingTests {
    private func iTunesString(_ metadata: [AVMetadataItem], _ identifier: AVMetadataIdentifier) async throws -> String? {
        guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first
        else { return nil }
        return try await item.load(.stringValue)
    }

    @Test func alacEncodeTagAndRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wavURL = dir.appendingPathComponent("in.wav")
        let alacURL = dir.appendingPathComponent("out.m4a")
        let pcm = try makeTestWAV(at: wavURL)

        let album = makeTestAlbum()
        let tags = TrackTags(album: album, track: album.tracks[0])
        let art = CoverArt(data: tinyJPEG, mimeType: "image/jpeg", source: .coverArtArchive)
        try await M4AEncoder(codec: .alac).encode(wav: wavURL, to: alacURL, tags: tags, art: art)

        #expect(try decodePCM(alacURL) == pcm, "lossless round trip")

        let metadata = try await AVURLAsset(url: alacURL).load(.metadata)
        #expect(try await iTunesString(metadata, .iTunesMetadataSongName) == "First Song")
        #expect(try await iTunesString(metadata, .iTunesMetadataAlbum) == "Test Album")

        // Picard-style freeform atoms carry the MusicBrainz identifiers, so
        // an M4A library is tagged as richly as a FLAC one.
        let trackID = try #require(M4AEncoder.freeformIdentifier(name: "MusicBrainz Track Id"))
        #expect(try await iTunesString(metadata, trackID) == "77777777-aaaa-bbbb-cccc-000000000007")
        let label = try #require(M4AEncoder.freeformIdentifier(name: "LABEL"))
        #expect(try await iTunesString(metadata, label) == "Test Records")
        let isrc = try #require(M4AEncoder.freeformIdentifier(name: "ISRC"))
        #expect(try await iTunesString(metadata, isrc) == "NLA319700019")

        let artItem = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .iTunesMetadataCoverArt).first
        let artData = try await artItem?.load(.dataValue)
        #expect(artData == tinyJPEG, "cover art bytes intact")
    }

    @Test func everyTagKeyHasAVorbisName() {
        let names = TagKey.allCases.map(\.vorbisName)
        #expect(Set(names).count == names.count, "Vorbis names are unique")
        let tags = TrackTags(album: makeTestAlbum(), track: makeTestAlbum().tracks[0])
        #expect(tags.fields.contains(TagField(.originalYear, "1997")))
        #expect(tags.fields.contains(TagField(.isrc, "NLA319700019")))
        #expect(tags.vorbisComments.contains { $0 == ("MUSICBRAINZ_TRACKID", "77777777-aaaa-bbbb-cccc-000000000007") })
    }

    @Test func aacEncodeTagAndDecode() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wavURL = dir.appendingPathComponent("in.wav")
        let aacURL = dir.appendingPathComponent("out.m4a")
        let pcm = try makeTestWAV(at: wavURL)

        let album = makeTestAlbum()
        let tags = TrackTags(album: album, track: album.tracks[0])
        let art = CoverArt(data: tinyJPEG, mimeType: "image/jpeg", source: .coverArtArchive)
        try await M4AEncoder(codec: .aac).encode(wav: wavURL, to: aacURL, tags: tags, art: art)

        // Lossy: bytes differ, but the decoded duration must survive (the
        // m4a edit list trims the codec's priming/remainder frames) within
        // one AAC packet (1024 frames × 4 bytes).
        let decoded = try decodePCM(aacURL)
        #expect(abs(decoded.count - pcm.count) <= 1024 * 4, "duration preserved")

        // 2 s stereo at 256 kbps must land far below the ~350 KB WAV.
        let size = try #require(FileManager.default.attributesOfItem(atPath: aacURL.path)[.size] as? Int)
        #expect(size < 150_000, "actually lossy-compressed (got \(size) bytes)")

        let metadata = try await AVURLAsset(url: aacURL).load(.metadata)
        #expect(try await iTunesString(metadata, .iTunesMetadataSongName) == "First Song")
        #expect(try await iTunesString(metadata, .iTunesMetadataAlbum) == "Test Album")

        let artItem = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .iTunesMetadataCoverArt).first
        let artData = try await artItem?.load(.dataValue)
        #expect(artData == tinyJPEG, "cover art bytes intact")
    }
}
