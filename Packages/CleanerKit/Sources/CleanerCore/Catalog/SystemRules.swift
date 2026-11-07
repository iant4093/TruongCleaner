import Foundation

/// Rules from `docs/RULE_CATALOG.md` §4.10 (System Data), in catalog order. All are Info rows:
/// they show a size or a note, explain it, and name the fix macOS allows. None has an action.
///
/// Rows with a folder to measure use `.measureOnly`. Rows with no folder use `.computed`; the key is
/// the rule ID, and the System Data page works the value out itself.
///
/// `sanctionedCommand` is text for the "Copy Command" button. The app never runs it.
enum SystemRules {
    /// Every rule in the System Data section.
    static let all: [Rule] = [
        snapshots,
        purgeable,
        spotlight,
        swap,
        aiAssets,
        rosetta,
        updates,
        unexplained,
    ]

    private static func settings(_ pane: String) -> URL? {
        URL(string: "x-apple.systempreferences:\(pane)")
    }

    /// The list of local APFS snapshots, from the read-only `tmutil listlocalsnapshots /` (works as the user).
    static let snapshots = Rule(
        id: "system.snapshots",
        category: .system,
        tier: .info,
        roots: [],
        match: .computed("system.snapshots"),
        access: .user,
        action: .none,
        title: "Local snapshots",
        explain: """
            Time Machine keeps snapshots on this Mac, and macOS removes them when space is needed. \
            To thin them now, open Time Machine settings, or copy the command and run it in Terminal. \
            The command asks for an administrator password.
            """,
        sanctionedCommand: "sudo tmutil thinlocalsnapshots / 999999999999 4",
        settingsURL: settings("com.apple.Time-Machine-Settings.extension")
    )

    /// Purgeable space: what macOS can free by itself.
    static let purgeable = Rule(
        id: "system.purgeable",
        category: .system,
        tier: .info,
        roots: [],
        match: .computed("system.purgeable"),
        access: .user,
        action: .none,
        title: "Purgeable space",
        explain: "Space macOS frees by itself when something needs it. Nothing to do."
    )

    /// The Spotlight index. Needs root to read, so the size is often unknown.
    static let spotlight = Rule(
        id: "system.spotlight",
        category: .system,
        tier: .info,
        roots: [.absolute(["System", "Volumes", "Data", ".Spotlight-V100"])],
        match: .measureOnly,
        access: .root,
        action: .none,
        title: "Spotlight index",
        explain: """
            The search index. If it is damaged, you can rebuild it with the command below. \
            Spotlight search is slow or incomplete for a long time while it rebuilds. \
            The command asks for an administrator password.
            """,
        sanctionedCommand: "sudo mdutil -E /System/Volumes/Data"
    )

    /// Swap in use, from `sysctl vm.swapusage`.
    static let swap = Rule(
        id: "system.swap",
        category: .system,
        tier: .info,
        roots: [],
        match: .computed("system.swap"),
        access: .user,
        action: .none,
        title: "Swap",
        explain: "Memory that spilled onto the disk. Quit memory-heavy apps or restart to release it."
    )

    /// On-device assets for Apple Intelligence, Siri and dictation.
    static let aiAssets = Rule(
        id: "system.aiAssets",
        category: .system,
        tier: .info,
        roots: [.absolute(["System", "Library", "AssetsV2"])],
        match: .measureOnly,
        access: .user,
        action: .none,
        title: "Apple Intelligence and language assets",
        explain: """
            Models and language data that macOS downloads. To remove some, open Apple Intelligence & Siri \
            settings, or change dictation languages in Keyboard settings.
            """,
        settingsURL: settings("com.apple.Siri-Settings.extension")
    )

    /// Rosetta. A note only.
    static let rosetta = Rule(
        id: "system.rosetta",
        category: .system,
        tier: .info,
        roots: [],
        match: .computed("system.rosetta"),
        access: .user,
        action: .none,
        title: "Rosetta",
        explain: "The translator for Intel apps. macOS manages it, and it comes back with OS updates."
    )

    /// Folders where macOS stages updates. Readable only with root, so the size is often unknown.
    ///
    /// The catalog says "staging folders" without listing them. These two are the update and
    /// installer staging folders in the protected list.
    static let updates = Rule(
        id: "system.updates",
        category: .system,
        tier: .info,
        roots: [
            .absolute(["Library", "Updates"]),
            .absolute(["macOS Install Data"]),
        ],
        match: .measureOnly,
        access: .root,
        action: .none,
        title: "Update files",
        explain: "Files macOS stages for an update. Never delete them. Restart or finish the update to release them."
    )

    /// Used space minus every measured category.
    static let unexplained = Rule(
        id: "system.unexplained",
        category: .system,
        tier: .info,
        roots: [],
        match: .computed("system.unexplained"),
        access: .user,
        action: .none,
        title: "Unexplained",
        explain: """
            Used space that no measured category accounts for. It can be system files, snapshots, \
            or folders this app cannot read. macOS does not report a breakdown.
            """
    )
}
