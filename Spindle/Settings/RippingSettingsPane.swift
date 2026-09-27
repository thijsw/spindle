import DiscDrive
import SpindleCore
import SwiftUI

struct RippingSettingsPane: View {
    @Environment(SettingsStore.self) private var model
    @State private var driveName: String?
    @State private var driveKey: String?
    @State private var suggestedOffset: Int?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Mode", selection: $model.preferences.ripMode) {
                    Text("Secure (re-read on errors)").tag(Preferences.RipMode.secure)
                    Text("Fast (single pass)").tag(Preferences.RipMode.fast)
                }
                Stepper(
                    "Re-read attempts: \(model.preferences.maxRetries)",
                    value: $model.preferences.maxRetries,
                    in: 2...64
                )
                .disabled(model.preferences.ripMode == .fast)
            } header: {
                Text("Accuracy")
            } footer: {
                Text("Secure mode re-reads sectors the drive flags as damaged until consecutive reads agree, and verifies the result against the CUETools database.")
                    .settingsFooter()
            }

            Section {
                if let driveKey {
                    TextField(
                        "Offset for \(driveName ?? driveKey) (samples)",
                        value: offsetBinding(for: driveKey),
                        format: .number
                    )
                    if let suggestedOffset, model.preferences.driveOffsets[driveKey] == nil {
                        Button("Use typical value for this drive family (\(suggestedOffset.formatted(.number.sign(strategy: .always()))))") {
                            model.preferences.driveOffsets[driveKey] = suggestedOffset
                        }
                        .controlSize(.small)
                    }
                } else {
                    Text("Insert a disc to configure the drive's read offset.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Drive read offset")
            } footer: {
                Text("Each drive model reads a fixed number of samples early or late. Setting the AccurateRip-style offset makes rips byte-identical with other rippers. A CTDB-verified rip confirms the value is right.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .task(detectDrive)
    }

    /// SwiftUI drives setters at display rate; an unchanged write still
    /// re-renders every preferences observer, so assign only on change.
    private func offsetBinding(for driveKey: String) -> Binding<Int> {
        Binding(
            get: { model.preferences.driveOffsets[driveKey] ?? 0 },
            set: { newValue in
                guard model.preferences.driveOffsets[driveKey] != newValue else { return }
                model.preferences.driveOffsets[driveKey] = newValue
            }
        )
    }

    /// IOKit registry traversal is synchronous and can stall for seconds
    /// while a rip is holding the drive — so it must never run on the main
    /// thread, or the whole app beach-balls.
    @Sendable private func detectDrive() async {
        let found = await Task.detached(priority: .utility) { () -> (String, String, Int?)? in
            guard let bsd = DiscEnumerator.presentCDMedia().first,
                  let identity = DiscEnumerator.driveIdentity(forMediaBSDName: bsd)
            else { return nil }
            return (identity.displayName, identity.offsetKey, DriveOffsetTable.suggestion(for: identity)?.samples)
        }.value
        guard let found else { return }
        driveName = found.0
        driveKey = found.1
        suggestedOffset = found.2
    }
}
