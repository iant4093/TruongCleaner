import AppKit

/// The few AppKit calls this page needs. None of them changes a file, and none runs a command.
@MainActor
enum SystemDataActions {
    /// Puts text on the clipboard.
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Opens a System Settings link. Returns `false` when macOS could not open it.
    @discardableResult
    static func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}
