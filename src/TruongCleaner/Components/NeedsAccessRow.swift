import SwiftUI

/// A row that says why a size is missing: macOS would not let the app open a folder.
///
/// A size that could not be read is unknown, not zero (REQ-SCAN-04).
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                }
                Spacer(minLength: 8)
                if kind == .fullDiskAccess {
                    Button("Open Privacy Settings") {
                        showFallback = !openPrivacySettings()
                    }
                    .controlSize(.small)
                    .accessibilityHint("Opens System Settings so you can turn on Full Disk Access")
                }
            }
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if showFallback {
                Text("Open System Settings > Privacy & Security > Full Disk Access and turn on TruongCleaner.")
                    .font(.callout)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch kind {
        case .fullDiskAccess: "Needs Full Disk Access"
        case .refusedByMacOS: "macOS did not allow access"
        case .administratorOnly: "Only macOS can read this"
        }
    }

    private var detail: String {
        switch kind {
        case .fullDiskAccess:
            "Some folders could not be opened, so their size is unknown, not zero."
        case .refusedByMacOS:
            "Full Disk Access is on, but macOS still refused some folders. Their size is unknown, not zero."
        case .administratorOnly:
            "This needs an administrator. TruongCleaner does not change it."
        }
    }
}
