import Foundation

/// The synthetic rule `apps.uninstall` that cleans one app and its leftovers (`docs/UNINSTALLER.md` §4).
///
/// It is not in `Catalog`: one rule is built per uninstall, for one app. Only `installers.macOS` and this
/// rule may remove a whole `.app` (`Rule.allowsWholeBundle`).
public enum UninstallRule {
    /// The rule's ID, in history and in the gate.
    public static let id = Rule.uninstallRuleID

    /// The rule and the concrete folders it may act in.
    public struct Setup: Sendable {
        /// The rule for this app.
        public let rule: Rule
        /// The folders to pass as `GateContext.expandedRoots` and `PlannedItem.expandedRoots`.
        public let expandedRoots: [URL]
    }

    /// Builds the rule for `app`, or says why the app cannot be uninstalled.
    ///
    /// The rule has tier Review and action Trash. Its roots are the searched folders of `~/Library` and
    /// the folder that holds the app. Its one owner is the app itself, so the gate refuses every item
    /// while the app runs. Info items of `/Library` are not roots: they are never deleted.
    ///
    /// - Parameters:
    ///   - app: The app to remove.
    ///   - isRunning: Whether the app is running; nil when unknown (the app is then refused).
    ///   - context: This Mac's folders and TruongCleaner's own identity.
    public static func make(
        for app: AppFacts, isRunning: Bool?, context: UninstallContext
    ) -> Result<Setup, UninstallRefusal> {
        if let refusal = UninstallEligibility.check(app, isRunning: isRunning, context: context) {
            return .failure(refusal)
        }
        guard let bundleID = app.bundleID else { return .failure(.noBundleID) }

        let library = context.home.appending(path: "Library", directoryHint: .isDirectory)
        var specs = LeftoverFolder.userFolders.map {
            RootSpec(base: .home, components: ["Library"] + $0.components)
        }
        var roots = LeftoverFolder.userFolders.map { folder in
            folder.components.reduce(library) { $0.appending(path: $1, directoryHint: .isDirectory) }
        }
        let parent = app.url.deletingLastPathComponent()
        let parentParts = parent.path(percentEncoded: false).split(separator: "/", omittingEmptySubsequences: true)
        specs.append(RootSpec(base: .absolute, components: parentParts.map(String.init)))
        roots.append(URL(filePath: parent.path(percentEncoded: false), directoryHint: .isDirectory))

        let rule = Rule(
            id: id,
            category: .apps,
            tier: .review,
            roots: specs,
            match: .children,
            depth: 1,
            guards: Guards(owners: [.bundleID(bundleID)]),
            access: .user,
            action: .trash,
            title: "Uninstall \(app.title)",
            explain: "Moves the app and the files it left in your Library to the Trash."
        )
        return .success(Setup(rule: rule, expandedRoots: roots))
    }
}
