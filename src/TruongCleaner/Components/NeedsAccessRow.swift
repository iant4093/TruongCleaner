import SwiftUI

/// One line that says why sizes are missing: macOS would not let the app open some folders.
///
/// A size that could not be read is unknown, not zero (REQ-SCAN-04).
///
/// ```text
/// 🔒 Some folders need Full Disk Access                         [Open Privacy Settings]
/// ```
///
/// The line starts at the titles of the rows above it (`itemRowLeadingColumns`) and its button ends at the
/// same x as their actions. Put one under the last row of a section, not one per row. The longer
/// explanation is in the tooltip and read by VoiceOver.
struct NeedsAccessRow: View {
    /// What kind of access is missing.
    enum Kind {
        /// Full Disk Access is off. The user can turn it on.
        case fullDiskAccess
        /// Full Disk Access is on, but macOS still refused some folders.
        case refusedByMacOS
        /// Only an administrator or macOS itself can read it. Full Disk Access does not help.
        case administratorOnly
    }

    let kind: Kind
    /// Opens the Privacy pane. Returns `false` when macOS could not open it.
    var openPrivacySettings: () -> Bool = { false }

    @State private var showFallback = false
    @SwiftUI.Environment(\.itemRowLeadingColumns) private var leading

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label {
                    Text(title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } icon: {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                }
                .font(.callout)
                .help(detail)
                .frame(maxWidth: .infinity, alignment: .leading)
                if kind == .fullDiskAccess {
                    Button("Open Privacy Settings") {
                        showFallback = !openPrivacySettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .help(detail)
                    .accessibilityHint("Opens System Settings so you can turn on Full Disk Access")
                }
            }
            if showFallback {
                Text("Open System Settings > Privacy & Security > Full Disk Access and turn on TruongCleaner.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, ItemRowMetrics.titleOffset(for: leading))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }

    private var title: String {
        switch kind {
        case .fullDiskAccess: "Some folders need Full Disk Access"
        case .refusedByMacOS: "macOS did not allow access to some folders"
        case .administratorOnly: "Only an administrator can read some folders"
        }
    }

    private var detail: String {
        switch kind {
        case .fullDiskAccess:
            "Some folders could not be opened, so their size is unknown, not zero."
        case .refusedByMacOS:
            "Full Disk Access is on, but macOS still refused some folders. Their size is unknown, not zero."
        case .administratorOnly:
            "This needs an administrator. TruongCleaner does not change it. The size is unknown, not zero."
        }
    }
}
