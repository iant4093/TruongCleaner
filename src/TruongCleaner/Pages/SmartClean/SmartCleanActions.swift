import AppKit

/// The few AppKit calls Smart Clean needs. None of them changes a file.
@MainActor
enum SmartCleanActions {
    private static let privacyPane = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )

    /// Shows an item in a Finder window.
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens the Full Disk Access list in System Settings. Returns `false` when macOS could not open it.
    static func openPrivacySettings() -> Bool {
        guard let privacyPane else { return false }
        return NSWorkspace.shared.open(privacyPane)
    }
}
