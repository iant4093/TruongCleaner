import SwiftUI

/// Delete mode and update checks.
struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let updates = model.updates

        Form {
            Section("Cleaning") {
                Picker("When cleaning", selection: $settings.deleteMode) {
                    ForEach(DeleteModeSetting.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text(
                    "Move to Trash keeps items in the Trash so you can put them back. "
                        + "Delete immediately frees the space at once and cannot be undone, "
                        + "so TruongCleaner asks you to confirm it each time."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $settings.checksForUpdatesAutomatically)
                Text(
                    "Once a day, TruongCleaner asks GitHub for the newest build. "
                        + "It sends nothing else and never installs anything by itself."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                LabeledContent("Last checked") {
                    if let date = updates.lastChecked {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text("Never")
                    }
                }
                LabeledContent {
                    Button("Check Now") {
                        Task { await updates.checkNow() }
                    }
                    .disabled(updates.isChecking)
                } label: {
                    if updates.isChecking {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Checking for updates")
                    } else if let text = statusText(updates.manualResult) {
                        Text(text).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func statusText(_ result: UpdateChecker.ManualResult?) -> String? {
        switch result {
        case nil: nil
        case .upToDate: "TruongCleaner is up to date."
        case .available(let build): "Build \(build) is available."
        case .failed: "Could not check for updates. Try again later."
        }
    }
}
