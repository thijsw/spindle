import Foundation
import Metadata
import Naming
import Testing

@Suite struct NamingTemplateTests {
    private var album: ResolvedAlbum {
        var album = ResolvedAlbum.fallback(cdText: nil, discID: nil, trackCount: 2)
        album.album = "Hello Nasty"
        album.albumArtist = "Beastie Boys"
        album.date = "1998-07-14"
        album.tracks[0].title = "Intergalactic"
        return album
    }

    @Test func standardTemplate() {
        let path = NamingTemplate.standard.render(album: album, track: album.tracks[0])
        #expect(path == "Beastie Boys/Hello Nasty (1998)/01 - Intergalactic")
    }

    @Test func groupsDropWhenATokenInsideIsEmpty() {
        var undated = album
        undated.date = nil
        let path = NamingTemplate.standard.render(album: undated, track: undated.tracks[0])
        #expect(path == "Beastie Boys/Hello Nasty/01 - Intergalactic", "the ' (year)' group vanishes")
    }

    /// Regression: an unclosed "[" used to swallow everything after it.
    @Test func unclosedGroupKeepsTheTrailingText() {
        let template = NamingTemplate(template: "{album} [{year}/{track} - {title}")
        let path = template.render(album: album, track: album.tracks[0])
        #expect(path == "Hello Nasty 1998/01 - Intergalactic")

        var undated = album
        undated.date = nil
        #expect(
            NamingTemplate(template: "{album}[ {year}").render(album: undated, track: undated.tracks[0]) == "Hello Nasty",
            "an unclosed group with an empty token is dropped like a closed one"
        )
    }

    @Test func unknownTokensRenderEmptyAndSlashesInValuesBecomeDashes() {
        var slashy = album
        slashy.tracks[0].title = "AC/DC Medley"
        let path = NamingTemplate(template: "{nope}{track} - {title}").render(album: slashy, track: slashy.tracks[0])
        #expect(path == "01 - AC-DC Medley")
    }
}
