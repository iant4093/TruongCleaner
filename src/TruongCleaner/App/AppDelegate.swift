import AppKit

/// Stops Quit (⌘Q, the Dock menu, log out) while a clean is running.
///
/// Quitting in the middle of a clean would lose the result sheet and its Put Back, and would orphan
/// an owner command (Homebrew, Docker, simulators) before its history line is written. The app asks
/// the user to wait instead. Nothing else about quitting changes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The model whose ``AppModel/isBusy`` decides. Set once by `TruongCleanerApp`.
    static weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.model?.isBusy == true else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "A clean is still running"
        alert.informativeText = "TruongCleaner is still changing files. Quit after it has finished, "
            + "so the result is complete and can be undone."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return .terminateCancel
    }
}
