import AppKit
import CleanerActions
import Foundation

/// Shows an app's name instead of its bundle ID in messages such as "com.apple.dt.Xcode is open".
///
/// Display only. The name never decides anything: the safety gate still compares the bundle ID.
@MainActor
enum AppName {
    private static var names: [String: String] = [:]

    /// The app's display name for a bundle ID, or `owner` unchanged when it is not a bundle ID of an
    /// installed app (a process name such as `xcodebuild`, or an app Launch Services does not know).
    static func display(for owner: String) -> String {
        if let name = names[owner] { return name }
        guard looksLikeBundleID(owner),
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: owner),
            let bundle = Bundle(url: url)
        else { return owner }
        let name =
            (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        guard !name.isEmpty else { return owner }
        names[owner] = name
        return name
    }

    private static func looksLikeBundleID(_ text: String) -> Bool {
        text.contains(".") && !text.contains(where: { $0 == " " || $0 == "/" })
    }
}

extension DenyReason {
    /// `userMessage` with an app's name where the kit only had its bundle ID. Read on the main actor.
    @MainActor
    var displayMessage: String {
        if case .ownerOpen(let owner) = self { return "\(AppName.display(for: owner)) is open" }
        return userMessage
    }
}
