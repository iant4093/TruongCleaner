import SwiftUI

/// Shown at the top of Overview when a newer build exists (REQ-DIST-04).
struct UpdateBanner: View {
    let release: ReleaseInfo
    let onDismiss: () -> Void
    @Environment(\.openURL) private var openURL
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("TruongCleaner Build \(release.buildNumber) is available")
                    .font(.headline)
                progressOrHint
            }
            Spacer(minLength: 8)
            if !model.updates.latestIsUnsigned {
                if model.updates.canCancelInstall {
                    Button("Cancel") { model.updates.cancelInstall() }
                }
                Button("Install Update") { model.updates.install() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.updates.canInstall)
                    .help(model.updates.installBlocker ?? "Download, check and install this build, then reopen")
            }
            Button("Copy Install Command") { SettingsActions.copy(UpdateChecker.installCommand) }
            Button("View Release") { openURL(release.pageURL) }
                .help(release.name)
            Button("Dismiss", systemImage: "xmark") { onDismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Hide until the next build")
        }
    }

    @ViewBuilder
    private var progressOrHint: some View {
        switch model.updates.installState {
        case .idle:
            Text(
                model.updates.installBlocker
                    ?? "Install it here, or copy the command for Terminal. macOS may ask for Full Disk Access again afterwards."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        case .downloading(let fraction):
            ProgressView(value: fraction) { Text("Downloading…") }
        case .verifying:
            ProgressView { Text("Checking the download…") }
        case .ready, .installing:
            ProgressView { Text("Installing and reopening…") }
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
        }
    }
}
