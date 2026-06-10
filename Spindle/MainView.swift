import SpindleCore
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let error = model.startupError {
                ContentUnavailableView(
                    "Spindle can't reach the disc system",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if let job = model.activeJob {
                ActiveJobView(job: job)
            } else {
                IdleView()
            }

            if !model.backgroundJobs.isEmpty || !model.history.isEmpty {
                Divider()
                QueueStrip()
                    .frame(height: 76)
            }
        }
        .sheet(item: $model.pickerJobID) { _ in
            ReleasePickerSheet()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if let job = model.activeJob, !job.candidates.isEmpty {
                    Button {
                        model.pickerJobID = job.id
                    } label: {
                        Label("Choose album match", systemImage: "questionmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                    .help("Several releases match this disc — choose the right one")
                }
            }
            ToolbarItem(placement: .automatic) {
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Spindle Settings")
            }
        }
    }
}

extension JobID: Identifiable {
    public var id: UUID { raw }
}

struct IdleView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "opticaldisc")
                .font(.system(size: 96, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("Insert an audio CD")
                .font(.title2)
                .foregroundStyle(.secondary)
            Group {
                if let destination = model.preferences.destination {
                    Text("Ripping to \(destination.displayName)")
                } else {
                    Text("No destination configured yet — open Settings to pick one.")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ActiveJobView: View {
    @Environment(AppModel.self) private var model
    let job: JobSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                CoverArtView(image: model.coverArt(for: job.id))
                    .frame(width: 220, height: 220)

                Text(job.album?.album ?? "Audio CD")
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(job.album?.albumArtist ?? "Identifying…")
                    .font(.body)
                    .foregroundStyle(.secondary)
                if let year = job.album?.year {
                    Text(year)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }

                StagePill(stage: job.stage)

                if let summary = job.verificationSummary {
                    Label(summary, systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(width: 230)

            TrackTable(tracks: job.tracks)
        }
        .padding(20)
    }
}

struct CoverArtView: View {
    /// Pre-decoded by AppModel; never decoded in this body.
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.quaternary)
                    Image(systemName: "music.note")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 4, y: 2)
        .animation(.easeInOut(duration: 0.4), value: image)
    }
}

struct StagePill: View {
    let stage: JobStage

    var body: some View {
        HStack(spacing: 6) {
            if !stage.isTerminal {
                ProgressView()
                    .controlSize(.small)
            }
            Text(stage.label)
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(background, in: Capsule())
    }

    private var background: Color {
        switch stage {
        case .completed: .green.opacity(0.18)
        case .failed: .red.opacity(0.18)
        case .awaitingMetadata: .orange.opacity(0.18)
        default: .secondary.opacity(0.12)
        }
    }
}

struct TrackTable: View {
    let tracks: [TrackState]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(tracks) { track in
                    TrackRow(track: track)
                }
            }
        }
    }
}

struct TrackRow: View {
    let track: TrackState

    var body: some View {
        HStack(spacing: 10) {
            Text(String(format: "%02d", track.number))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)

            Text(track.title)
                .lineLimit(1)

            Spacer()

            Text(durationString)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.tertiary)

            statusView
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            track.number.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 5)
        )
    }

    private var durationString: String {
        let seconds = Int(track.durationSeconds.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    @ViewBuilder private var statusView: some View {
        switch track.status {
        case .waiting:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.quaternary)
        case .ripping:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
        case .ripped:
            Image(systemName: "checkmark")
                .foregroundStyle(.secondary)
                .help("Ripped")
        case .verified(let matched):
            Image(systemName: matched ? "checkmark.seal.fill" : "exclamationmark.triangle")
                .foregroundStyle(matched ? Color.green : Color.orange)
                .help(matched ? "Verified against CTDB" : "Does not match CTDB — check the drive offset")
        case .encoded:
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
                .help("Encoded")
        case .transferred:
            Image(systemName: "checkmark.icloud.fill")
                .foregroundStyle(.green)
                .help("Transferred")
        case .failed(let reason):
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help(reason)
        }
    }
}

struct QueueStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.backgroundJobs) { job in
                    QueueChip(
                        title: job.displayTitle,
                        subtitle: job.stage.label,
                        systemImage: "gearshape.arrow.triangle.2.circlepath",
                        tint: .blue
                    )
                }
                ForEach(model.history.prefix(12)) { record in
                    QueueChip(
                        title: "\(record.artist) — \(record.album)",
                        subtitle: record.succeeded ? (record.detail ?? "Done") : (record.detail ?? "Failed"),
                        systemImage: record.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill",
                        tint: record.succeeded ? .green : .red
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.background.secondary)
    }
}

struct QueueChip: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 260)
    }
}

struct ReleasePickerSheet: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Which release is this disc?")
                .font(.title3.weight(.semibold))
            Text("MusicBrainz lists several editions matching this disc. Pick the one you have — check country, label, and catalog number on the case.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List(model.pickerJob?.candidates ?? [], selection: $selection) { candidate in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("\(candidate.artist) — \(candidate.title)")
                            .font(.body.weight(.medium))
                        if candidate.confidence > 0 {
                            Text("best match")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.15), in: Capsule())
                        }
                    }
                    Text(detailLine(candidate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .tag(candidate.releaseMBID)
            }
            .frame(minHeight: 220)

            HStack {
                Button("Skip — Tag From Disc Only") {
                    model.declinePicker()
                }
                Spacer()
                Button("Cancel") {
                    model.pickerJobID = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Use This Release") {
                    if let selection { model.choose(candidateID: selection) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            selection = model.pickerJob?.candidates.first?.releaseMBID
        }
    }

    private func detailLine(_ candidate: ReleaseCandidate) -> String {
        var parts: [String] = []
        if let date = candidate.date { parts.append(date) }
        if let country = candidate.country { parts.append(country) }
        if let format = candidate.format { parts.append(format) }
        if let label = candidate.label { parts.append(label) }
        if let catalog = candidate.catalogNumber { parts.append(catalog) }
        if let barcode = candidate.barcode, !barcode.isEmpty { parts.append("barcode \(barcode)") }
        parts.append("\(candidate.trackCount) tracks")
        return parts.joined(separator: " · ")
    }
}
