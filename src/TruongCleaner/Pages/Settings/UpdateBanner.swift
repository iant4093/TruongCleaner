import SwiftUI

/// Shown at the top of Overview when a newer build exists (REQ-DIST-04).
struct UpdateBanner: View {
    let release: ReleaseInfo
    let onDismiss: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("TruongCleaner Build \(release.buildNumber) is available")
                    .font(.headline)
                Text("Copy the install command and run it in Terminal, or read the release notes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Copy Install Command") { SettingsActions.copy(UpdateChecker.installCommand) }
            Button("View Release") { openURL(release.pageURL) }
                .help(release.name)
            Button("Dismiss", systemImage: "xmark") { onDismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Hide until the next build")
        }
    }
}
