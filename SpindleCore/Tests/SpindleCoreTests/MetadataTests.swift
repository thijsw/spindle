import Foundation
import Metadata
import Testing

// A trimmed but structurally faithful WS/2 discid response (two releases,
// the first carrying our DiscID on its medium).
let discIDResponseJSON = """
{
  "id": "xUp1F2NkfP8s8jaeFn_Av3jNEI4-",
  "offset-count": 2,
  "releases": [
    {
      "id": "11111111-aaaa-bbbb-cccc-000000000001",
      "title": "Test Album",
      "status": "Official",
      "date": "1997-09-23",
      "country": "NL",
      "barcode": "724385522123",
      "release-group": {
        "id": "22222222-aaaa-bbbb-cccc-000000000002",
        "primary-type": "Album",
        "first-release-date": "1997-09-22"
      },
      "artist-credit": [
        { "name": "Some Artist", "joinphrase": " feat. ", "artist": { "id": "33333333-aaaa-bbbb-cccc-000000000003", "name": "Some Artist", "sort-name": "Artist, Some" } },
        { "name": "Guest", "artist": { "id": "44444444-aaaa-bbbb-cccc-000000000004", "name": "Guest", "sort-name": "Guest" } }
      ],
      "label-info": [
        { "catalog-number": "CAT-001", "label": { "id": "55555555-aaaa-bbbb-cccc-000000000005", "name": "Test Records" } }
      ],
      "media": [
        {
          "position": 1,
          "format": "CD",
          "track-count": 2,
          "discs": [ { "id": "xUp1F2NkfP8s8jaeFn_Av3jNEI4-" } ],
          "tracks": [
            {
              "id": "66666666-aaaa-bbbb-cccc-000000000006",
              "position": 1,
              "title": "First Song",
              "length": 200000,
              "recording": { "id": "77777777-aaaa-bbbb-cccc-000000000007", "title": "First Song", "length": 200000 }
            },
            {
              "id": "88888888-aaaa-bbbb-cccc-000000000008",
              "position": 2,
              "title": "Second Song",
              "recording": {
                "id": "99999999-aaaa-bbbb-cccc-000000000009",
                "title": "Second Song",
                "artist-credit": [ { "name": "Guest", "artist": { "id": "44444444-aaaa-bbbb-cccc-000000000004", "name": "Guest", "sort-name": "Guest" } } ]
              }
            }
          ]
        }
      ]
    },
    {
      "id": "aaaaaaaa-aaaa-bbbb-cccc-00000000000a",
      "title": "Test Album",
      "status": "Bootleg",
      "country": "XW",
      "media": [ { "position": 1, "format": "Digital Media", "track-count": 3 } ]
    }
  ]
}
"""

@Suite struct MusicBrainzModelTests {
    func decodeFixture() throws -> MBDiscIDResponse {
        try JSONDecoder().decode(MBDiscIDResponse.self, from: Data(discIDResponseJSON.utf8))
    }

    @Test func decodesDiscIDResponse() throws {
        let response = try decodeFixture()
        #expect(response.releases?.count == 2)

        let release = try #require(response.releases?.first)
        #expect(release.title == "Test Album")
        #expect((release.artistCredit ?? []).joinedName == "Some Artist feat. Guest")
        #expect(release.releaseGroup?.firstReleaseDate == "1997-09-22")
        #expect(release.media?.first?.discs?.first?.id == "xUp1F2NkfP8s8jaeFn_Av3jNEI4-")
    }

    @Test func resolvesAlbumFromRelease() throws {
        let release = try #require(decodeFixture().releases?.first)
        let album = try #require(ResolvedAlbum(
            release: release, discID: "xUp1F2NkfP8s8jaeFn_Av3jNEI4-", audioTrackCount: 2
        ))
        #expect(album.albumArtist == "Some Artist feat. Guest")
        #expect(album.year == "1997")
        #expect(album.originalDate == "1997-09-22")
        #expect(album.label == "Test Records")
        #expect(album.catalogNumber == "CAT-001")
        #expect(album.tracks.count == 2)
        #expect(album.tracks[0].artist == "Some Artist feat. Guest", "track 1 inherits album credit")
        #expect(album.tracks[1].artist == "Guest", "track 2 uses recording credit")
        #expect(album.tracks[1].recordingMBID == "99999999-aaaa-bbbb-cccc-000000000009")
    }

    @Test func fallbackAlbumsUseDiscIDAndCDText() {
        let fallback = ResolvedAlbum.fallback(cdText: nil, discID: "xUp1F2NkfP8s8jaeFn_Av3jNEI4-", trackCount: 3)
        #expect(fallback.album == "Unknown Album (xUp1F2Nk)")
        #expect(fallback.tracks.count == 3)
        #expect(fallback.tracks[2].title == "Track 03")

        let cdText = CDTextInfo(
            albumTitle: "Text Album",
            albumPerformer: "Text Artist",
            trackTitles: [1: "Eins", 2: "Zwei"],
            trackPerformers: [:]
        )
        let fromText = ResolvedAlbum.fallback(cdText: cdText, discID: nil, trackCount: 2)
        #expect(fromText.album == "Text Album")
        #expect(fromText.tracks[1].title == "Zwei")
    }
}

@Suite struct ReleaseScorerTests {
    @Test func ranksOfficialMatchingReleaseFirst() throws {
        let releases = try #require(
            try JSONDecoder().decode(MBDiscIDResponse.self, from: Data(discIDResponseJSON.utf8)).releases
        )
        let scorer = ReleaseScorer(preferences: MetadataPreferences(preferredCountries: ["NL"]))
        let ranked = scorer.rank(releases, discID: "xUp1F2NkfP8s8jaeFn_Av3jNEI4-", audioTrackCount: 2)
        #expect(ranked.count == 2)
        #expect(ranked[0].release.id == "11111111-aaaa-bbbb-cccc-000000000001")
        #expect(ranked[0].confidence > 0.7, "clear winner gets high confidence")
        #expect(ranked[1].confidence == 0, "runner-up has no confidence")

        let single = scorer.rank([releases[0]], discID: nil, audioTrackCount: 2)
        #expect(single[0].confidence > 0.7, "sole candidate gets high confidence")
    }
}
