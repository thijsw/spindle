import Metadata
import SpindleCore
import SwiftUI

/// One open tag-editing session: the job being tagged, the pre-filled draft
/// (CD-TEXT, fallback, or a MusicBrainz candidate), and the per-track
/// durations for display.
struct TagEditorSession: Identifiable {
    let jobID: JobID
    let draft: ResolvedAlbum
    let durations: [Int: Double] // track position → seconds

    var id: UUID { jobID.raw }
}

/// Hand-editing sheet for album tags: album fields up top, an editable
/// track list below. Saving resolves the job exactly like a picker choice.
struct TagEditorView: View {
    @Environment(AppModel.self) private var model
    let session: TagEditorSession

    @State private var draft: ResolvedAlbum
    @State private var year: String
    @State private var editTrackArtists: Bool
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case albumArtist, album, year
        case title(Int), artist(Int)
    }

    init(session: TagEditorSession) {
        self.session = session
        let draft = session.draft
        _draft = State(initialValue: draft)
        _year = State(initialValue: draft.year ?? "")
        // Per-track artists start visible only when they actually vary
        // (compilations); otherwise the album artist covers every track.
        _editTrackArtists = State(
            initialValue: draft.tracks.contains { $0.artist != draft.albumArtist }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Album Tags")
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)

            albumFields

            trackList

            Toggle("Tracks have different artists", isOn: $editTrackArtists.animation())
                .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancelTagEditor()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save Tags") {
                    model.submitTags(editedAlbum)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 580, height: 620)
        .onAppear {
            // The artist is the field most likely to need typing when the
            // disc is unknown; land the cursor there.
            focusedField = draft.albumArtist == "Unknown Artist" ? .albumArtist : nil
        }
    }

    private var subtitle: String {
        if draft.releaseMBID != nil {
            return "Correct anything that doesn't match your disc. Edits apply to the tags and file names, not to MusicBrainz."
        }
        return "This disc isn't on MusicBrainz. Enter its details — track durations are from the disc itself."
    }

    // MARK: Album fields

    private var albumFields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                label("Artist")
                TextField("Album artist", text: $draft.albumArtist)
                    .focused($focusedField, equals: .albumArtist)
            }
            GridRow {
                label("Album")
                TextField("Album title", text: $draft.album)
                    .focused($focusedField, equals: .album)
            }
            GridRow {
                label("Year")
                HStack(spacing: 10) {
                    TextField("YYYY", text: $year)
                        .focused($focusedField, equals: .year)
                        .frame(width: 60)
                        .onChange(of: year) { _, new in
                            year = String(new.filter(\.isNumber).prefix(4))
                        }
                    Spacer()
                    Text("Disc")
                        .foregroundStyle(.secondary)
                    TextField("", value: $draft.discNumber, format: .number)
                        .frame(width: 36)
                        .multilineTextAlignment(.center)
                    Text("of")
                        .foregroundStyle(.secondary)
                    TextField("", value: $draft.discTotal, format: .number)
                        .frame(width: 36)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    // MARK: Track list

    private var trackList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach($draft.tracks, id: \.position) { $track in
                    HStack(spacing: 8) {
                        Text(String(format: "%02d", track.position))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)

                        TextField("Title", text: $track.title)
                            .focused($focusedField, equals: .title(track.position))

                        if editTrackArtists {
                            TextField("Artist", text: $track.artist)
                                .focused($focusedField, equals: .artist(track.position))
                                .frame(width: 160)
                        }

                        Text(durationString(track.position))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        track.position.isMultiple(of: 2) ? Color.secondary.opacity(0.05) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                }
            }
            .padding(.vertical, 2)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxHeight: .infinity)
    }

    private func durationString(_ position: Int) -> String {
        guard let seconds = session.durations[position] else { return "" }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Saving

    private var isValid: Bool {
        !draft.albumArtist.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.album.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.tracks.contains { $0.title.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The draft with the year and artist rules applied.
    private var editedAlbum: ResolvedAlbum {
        var album = draft
        // Keep a candidate's full release date when its year wasn't touched;
        // a typed year replaces the date wholesale.
        if year != session.draft.year ?? "" {
            album.date = year.count == 4 ? year : nil
        }
        if !editTrackArtists {
            for index in album.tracks.indices {
                album.tracks[index].artist = album.albumArtist
            }
        }
        return album
    }
}
