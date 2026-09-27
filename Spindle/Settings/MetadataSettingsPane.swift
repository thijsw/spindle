import Metadata
import SpindleCore
import SwiftUI

struct MetadataSettingsPane: View {
    @Environment(SettingsStore.self) private var model
    /// Edited locally and applied on submit: parsing on every keystroke
    /// turned "NL," back into "NL" and ate the comma.
    @State private var countriesText = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Pick the best match automatically", isOn: $model.preferences.autoPickRelease)
                Text("When off — or when matches are too close to call — Spindle asks you to choose, without interrupting the rip.")
                    .settingsFooter()
                Picker("When no release matches", selection: $model.preferences.unmatchedDiscPolicy) {
                    Text("Ask me to edit the tags").tag(Preferences.UnmatchedDiscPolicy.askForTags)
                    Text("Tag as Unknown and continue").tag(Preferences.UnmatchedDiscPolicy.tagAsUnknown)
                }
                Text("Asking pauses only the encode — the disc still rips and ejects, so a batch keeps moving.")
                    .settingsFooter()
            }

            Section {
                TextField("Country codes", text: $countriesText, prompt: Text("NL, DE, GB, US"))
                    .onSubmit(applyCountries)
                    .onAppear { countriesText = model.preferences.metadata.preferredCountries.joined(separator: ", ") }
            } header: {
                Text("Preferred countries")
            } footer: {
                Text("Used to rank pressings when several releases match.")
                    .settingsFooter()
            }

            Section("Cover art") {
                Picker("Embedded size", selection: $model.preferences.coverArtSize) {
                    Text("500 px").tag(CoverArtSize.medium)
                    Text("1200 px").tag(CoverArtSize.large)
                    Text("Original").tag(CoverArtSize.original)
                }
                Toggle("Also save cover.jpg in each album folder", isOn: $model.preferences.writeCoverJPEG)
            }
        }
        .formStyle(.grouped)
    }

    private func applyCountries() {
        let codes = countriesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
        if codes != model.preferences.metadata.preferredCountries {
            model.preferences.metadata.preferredCountries = codes
        }
        countriesText = codes.joined(separator: ", ")
    }
}
