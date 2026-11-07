import AppKit

/// The few AppKit calls this page needs. None of them changes a file.
@MainActor
enum LargeFilesActions {
    /// Shows the files selected in a Finder window.
    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Puts the paths on the clipboard, one per line.
    static func copyPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    /// Asks the user for folders to search. Returns an empty list if they cancel.
    static func chooseFolders() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to search for large files."
        return panel.runModal() == .OK ? panel.urls : []
    }
}
