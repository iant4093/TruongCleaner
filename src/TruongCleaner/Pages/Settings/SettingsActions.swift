import AppKit

/// The few AppKit calls the Settings window and the update banner need. None of them changes a file.
@MainActor
enum SettingsActions {
    /// Asks the user for folders to exclude. Returns an empty list if they cancel.
    static func chooseFolders() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Exclude"
        panel.message = "Choose folders TruongCleaner must never scan or clean."
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Puts text on the clipboard.
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Opens a URL with its default app. Returns `false` when macOS could not open it.
    @discardableResult
    static func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}
