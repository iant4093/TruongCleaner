import AppKit
import Foundation
import Observation

/// Holds the latest probe report for the window.
@Observable @MainActor
final class ProbeModel {
    private(set) var report: ProbeReport?
    private(set) var isRunning = false
    private(set) var openStatus: String?
    private(set) var copyStatus: String?

    private var task: Task<Void, Never>?

    static let fullDiskAccessURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    static let privacyURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security")

    /// Starts a run. A newer run replaces one that is still going.
    func run() {
        task?.cancel()
        isRunning = true
        task = Task {
            let result = await ProbeRunner.run()
            guard !Task.isCancelled else { return }
            report = result
            isRunning = false
        }
    }

    /// Opens a System Settings URL and records whether `open` returned true.
    func open(_ url: URL?) {
        guard let url else {
            openStatus = "Could not build the URL."
            return
        }
        let accepted = NSWorkspace.shared.open(url)
        let time = Date().formatted(date: .omitted, time: .standard)
        openStatus = "NSWorkspace.open returned \(accepted) for \(url.absoluteString) at \(time)"
    }

    /// Copies the plain-text table to the pasteboard.
    func copyResults() {
        guard let report else {
            copyStatus = "Nothing to copy yet."
            return
        }
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(report.plainText(), forType: .string)
        copyStatus = copied ? "Copied \(report.results.count) rows." : "Copy failed."
    }
}
