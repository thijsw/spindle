import Foundation
import Metadata
import Naming
import Testing

@Suite struct NamingTemplateTests {
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

    @Test func nestedGroupsDropIndependently() {
        let template = NamingTemplate(template: "{album}[ ({year}[, {disc}])]")
        #expect(template.render(album: album, track: track) == "Test Album (1997)", "inner group drops, outer stays")
        var multi = album
        multi.discNumber = 2
        multi.discTotal = 2
        #expect(template.render(album: multi, track: track) == "Test Album (1997, 2)")
        var bare = multi
        bare.date = nil
        #expect(template.render(album: bare, track: track) == "Test Album", "an empty token anywhere drops its group and what nests in it")
    }

    /// Regression: an unclosed "[" used to swallow everything after it.
    @Test func unclosedGroupKeepsTheTrailingText() {
        let template = NamingTemplate(template: "{album} [{year}/{track} - {title}")
        #expect(template.render(album: album, track: track) == "Test Album 1997/01 - First Song")

        var undated = album
        undated.date = nil
        #expect(
            NamingTemplate(template: "{album}[ {year}").render(album: undated, track: undated.tracks[0]) == "Test Album",
            "an unclosed group with an empty token is dropped like a closed one"
        )
    }

    @Test func unknownTokensRenderEmptyAndSlashesInValuesBecomeDashes() {
        var slashy = album
        slashy.tracks[0].title = "AC/DC Medley"
        let path = NamingTemplate(template: "{nope}{track} - {title}").render(album: slashy, track: slashy.tracks[0])
        #expect(path == "01 - AC-DC Medley")
        #expect(NamingTemplate(template: "{originalyear} {title}").render(album: album, track: track) == "1997 First Song")
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
