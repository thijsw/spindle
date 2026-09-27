import Encoding
import Metadata
import SpindleCore
import SwiftUI

struct GeneralSettingsPane: View {
    @Environment(SettingsStore.self) private var model

    var body: some View {
        @Bindable var model = model
        return Form {
            Section {
                Picker("Format", selection: $model.preferences.format) {
                    Text("FLAC").tag(AudioFormat.flac)
                    Text("Apple Lossless (ALAC)").tag(AudioFormat.alac)
                    Text("AAC (256 kbps)").tag(AudioFormat.aac)
                }
            } footer: {
                Text("FLAC is ideal for Navidrome and most servers; ALAC plays natively in Apple apps. Both are lossless. AAC is lossy but far smaller — best when storage is tight.")
                    .settingsFooter()
            }

            Section {
                TextField("Template", text: $model.preferences.namingTemplate.template)
                    .font(.system(.body, design: .monospaced))
                Text(namingPreview)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } header: {
                Text("File names")
            } footer: {
                Text("Tokens: {albumartist} {album} {artist} {title} {track} {disc} {year} {originalyear}. Square brackets drop their content when a token inside is empty.")
                    .settingsFooter()
            }

            Section {
                Toggle("Write a rip log", isOn: $model.preferences.writeRipLog)
                Toggle("Write a cue sheet", isOn: $model.preferences.writeCueSheet)
            } header: {
                Text("Album folder extras")
            } footer: {
                Text("The log records the drive, offset, per-track checksums and CTDB verdicts — proof of an accurate rip. The cue sheet describes the track layout for players and burning tools. Both land next to the audio files.")
                    .settingsFooter()
            }

            Section("Behavior") {
                Picker("Eject the disc", selection: $model.preferences.ejectTiming) {
                    Text("As soon as audio is copied").tag(Preferences.EjectTiming.afterRip)
                    Text("After encoding and transfer finish").tag(Preferences.EjectTiming.afterEverything)
                }
                Toggle("Show notifications", isOn: $model.preferences.notificationsEnabled)
                Toggle("Show menu bar status", isOn: $model.preferences.showMenuBarExtra)
            }
        }
        .formStyle(.grouped)
    }

    private var namingPreview: String {
        var album = ResolvedAlbum.fallback(cdText: nil, discID: nil, trackCount: 1)
        album.album = "Hello Nasty"
        album.albumArtist = "Beastie Boys"
        album.date = "1998-07-14"
        var track = album.tracks[0]
        track.title = "Intergalactic"
        track.position = 7
        return "Preview: " + model.preferences.namingTemplate.render(album: album, track: track)
            + "." + model.preferences.format.fileExtension
    }
}
