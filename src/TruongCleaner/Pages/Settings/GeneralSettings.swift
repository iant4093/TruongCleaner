import SwiftUI

/// Delete mode and update checks.
struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

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
                        + "It sends nothing else and installs an update only when you press Install Update."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                LabeledContent("This version") { Text(UpdateChecker.versionText) }
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
                if let release = updates.latest {
                    installRows(release, updates: updates)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func installRows(_ release: ReleaseInfo, updates: UpdateChecker) -> some View {
        LabeledContent("Latest build") { Text("Build \(release.buildNumber)") }

        if updates.latestIsUnsigned {
            // The app installs only signed updates, so there is no Install button yet.
            Text(UpdateChecker.unsignedMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            installControls(updates: updates)
        }

        LabeledContent("Other ways") {
            HStack {
                Button("View Release Notes") { openURL(release.pageURL) }
                Button("Install with Terminal Instead") { SettingsActions.copy(UpdateChecker.installCommand) }
                    .help("Copies the install command. Paste it into Terminal.")
            }
        }
    }

    @ViewBuilder
    private func installControls(updates: UpdateChecker) -> some View {
        LabeledContent {
            HStack {
                if updates.canCancelInstall {
                    Button("Cancel") { updates.cancelInstall() }
                }
                Button("Install Update") { updates.install() }
                    .disabled(!updates.canInstall)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Install the update here")
                if let reason = updates.installBlocker {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
        }

        switch updates.installState {
        case .idle:
            EmptyView()
        case .downloading(let fraction):
            ProgressView(value: fraction) { Text("Downloading…") }
                .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
        case .verifying:
            ProgressView { Text("Checking the download…") }
        case .ready, .installing:
            ProgressView { Text("Installing and reopening…") }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Update failed. \(message)")
        }

        Text(
            "The app downloads the update from GitHub, checks its checksum and signature, "
                + "replaces itself, and reopens. The old copy goes to the Trash on the next launch. "
                + "macOS may ask for Full Disk Access again after an update."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
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
