import CleanerScanner
import SwiftUI

/// Full Disk Access status and the way to grant it (REQ-PERM-01, -02, -04).
struct PermissionsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var showFallbackHint = false
    @State private var isChecking = false

    private static let privacyPane = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )
    private static let securitySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security")

    var body: some View {
        Form {
            Section("Full Disk Access") {
                LabeledContent("Status") {
                    Label(title, systemImage: symbol)
                        .foregroundStyle(color)
                }
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Open Privacy Settings") { openPrivacySettings() }
                    Button("Check Again") {
                        Task {
                            isChecking = true
                            await model.refreshAccess()
                            isChecking = false
                        }
                    }
                    .disabled(isChecking)
                }
                if showFallbackHint {
                    Text("Find TruongCleaner under Full Disk Access.")
                        .font(.callout)
                }
            }

            Section {
                Text(
                    "TruongCleaner works without Full Disk Access. Folders that need it are marked "
                        + "\"Needs Full Disk Access\" and their size shows as unknown, not zero. "
                        + "After you install an update, macOS may ask for this permission again, "
                        + "because the app is signed ad hoc."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var title: String {
        switch model.access {
        case .granted: "Granted"
        case .notGranted: "Not granted"
        case .unknown: "Unknown"
        }
    }

    private var symbol: String {
        switch model.access {
        case .granted: "checkmark.circle.fill"
        case .notGranted: "lock.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    private var color: Color {
        switch model.access {
        case .granted: .green
        case .notGranted: .orange
        case .unknown: .secondary
        }
    }

    private var explanation: String {
        switch model.access {
        case .granted:
            "TruongCleaner can open protected folders, so it can measure everything its rules cover."
        case .notGranted:
            "macOS refused to open protected folders such as Safari and Mail. Turn on "
                + "TruongCleaner in Full Disk Access to measure and clean them."
        case .unknown:
            "TruongCleaner could not tell. The folders it checks are missing or gave an unclear answer. "
                + "Choose Check Again after changing the setting."
        }
    }

    private func openPrivacySettings() {
        showFallbackHint = false
        if let pane = Self.privacyPane, SettingsActions.open(pane) { return }
        showFallbackHint = true
        if let general = Self.securitySettings { SettingsActions.open(general) }
    }
}
