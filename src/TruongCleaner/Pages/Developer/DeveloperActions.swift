import AppKit

/// The few AppKit calls the Developer page needs. None of them changes a file or runs a command.
@MainActor
enum DeveloperActions {
    /// Bundle ID of Docker Desktop.
    private static let dockerDesktopBundleID = "com.docker.docker"

    /// Asks the user for project folders to search. Returns an empty list if they cancel.
    static func chooseProjectFolders() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders that hold your projects, such as ~/Code."
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Where Docker Desktop is installed, or `nil` when it is not.
    static func dockerDesktopURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: dockerDesktopBundleID)
    }

    /// Opens Docker Desktop. Returns `false` when it is not installed or macOS could not open it.
    @discardableResult
    static func openDockerDesktop() -> Bool {
        guard let url = dockerDesktopURL() else { return false }
        return NSWorkspace.shared.open(url)
    }
}
