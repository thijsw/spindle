import Encoding
import Foundation
import Metadata
import Naming
import Testing

@testable import SpindleCore

@Suite struct DeliveryPlanTests {
    private var album: ResolvedAlbum {
        var album = ResolvedAlbum.fallback(cdText: nil, discID: nil, trackCount: 3)
        album.albumArtist = "Artist"
        album.album = "Album"
        album.date = "2001"
        album.tracks[0].title = "One"
        album.tracks[1].title = "Two"
        album.tracks[2].title = "Three"
        return album
    }

    @Test func singleFolderGetsAudioThenExtrasInOrder() {
        let plan = DeliveryPlan.build(
            album: album, rippedTrackNumbers: [1, 2, 3], template: .standard, format: .flac,
            coverExtension: "jpg", ripLog: true, cueSheet: true
        )
        #expect(plan.files.map(\.relativePath) == [
            "Artist/Album (2001)/01 - One.flac",
            "Artist/Album (2001)/02 - Two.flac",
            "Artist/Album (2001)/03 - Three.flac",
            "Artist/Album (2001)/cover.jpg",
            "Artist/Album (2001)/Artist - Album.log",
            "Artist/Album (2001)/Artist - Album.cue",
        ])
        guard case .cueSheet(let names)? = plan.files.last?.content else {
            Issue.record("last file should be the cue sheet")
            return
        }
        #expect(names == [1: "01 - One.flac", 2: "02 - Two.flac", 3: "03 - Three.flac"])
    }

    @Test func abandonedTracksAreSimplyAbsent() {
        let plan = DeliveryPlan.build(
            album: album, rippedTrackNumbers: [1, 3], template: .standard, format: .aac,
            coverExtension: nil, ripLog: false, cueSheet: false
        )
        #expect(plan.files.map(\.content) == [.audio(trackNumber: 1), .audio(trackNumber: 3)])
        #expect(plan.files.allSatisfy { $0.relativePath.hasSuffix(".m4a") })
    }

    /// A per-disc folder template puts each disc's extras in its own folder,
    /// and each cue sheet only lists the files beside it.
    @Test func discFoldersGetTheirOwnExtras() {
        var disc2 = album
        disc2.discNumber = 2
        disc2.discTotal = 2
        let plan = DeliveryPlan.build(
            album: disc2, rippedTrackNumbers: [1, 2], template: .discFolders, format: .flac,
            coverExtension: "png", ripLog: true, cueSheet: true
        )
        #expect(plan.files.map(\.relativePath) == [
            "Artist/Album (2001)/Disc 2/01 - One.flac",
            "Artist/Album (2001)/Disc 2/02 - Two.flac",
            "Artist/Album (2001)/Disc 2/cover.png",
            "Artist/Album (2001)/Disc 2/Artist - Album.log",
            "Artist/Album (2001)/Disc 2/Artist - Album.cue",
        ])
    }
}
