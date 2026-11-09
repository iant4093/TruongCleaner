import Foundation

/// Who signed an app, as far as the code signature says (`docs/UNINSTALLER.md` §1).
public enum AppSignature: Sendable, Hashable {
    /// Signed with Apple's own anchor (Apple's apps).
    case apple
    /// Unsigned, or signed by someone else.
    case other
    /// The signature could not be read. Callers treat this like a refusal.
    case unknown
}

/// What the uninstaller knows about one installed app, read from its `Info.plist` and signature.
///
/// Plain values only. Reading them is `CleanerScanner.AppInventory`'s job.
public struct AppFacts: Sendable, Hashable, Identifiable {
    /// The `.app` folder.
    public var url: URL
    /// `CFBundleIdentifier`. Nil when the app has none, which makes it ineligible.
    public var bundleID: String?
    /// `CFBundleName`.
    public var name: String?
    /// `CFBundleDisplayName`.
    public var displayName: String?
    /// `CFBundleExecutable`.
    public var executableName: String?
    /// `CFBundleShortVersionString`, or `CFBundleVersion` when there is no short one.
    public var version: String?
    /// Developer team ID from the code signature. Nil for unsigned apps and Apple's own.
    public var teamID: String?
    /// Who signed the app.
    public var signature: AppSignature
    /// User ID that owns the `.app` folder. Nil when it could not be read.
    public var ownerUID: UInt32?
    /// Whether the user may remove entries from the folder that holds the app. Nil when unknown.
    public var parentIsWritable: Bool?

    /// Creates app facts.
    public init(
        url: URL,
        bundleID: String? = nil,
        name: String? = nil,
        displayName: String? = nil,
        executableName: String? = nil,
        version: String? = nil,
        teamID: String? = nil,
        signature: AppSignature = .other,
        ownerUID: UInt32? = nil,
        parentIsWritable: Bool? = nil
    ) {
        self.url = url
        self.bundleID = bundleID
        self.name = name
        self.displayName = displayName
        self.executableName = executableName
        self.version = version
        self.teamID = teamID
        self.signature = signature
        self.ownerUID = ownerUID
        self.parentIsWritable = parentIsWritable
    }

    /// The path of the `.app` folder, which identifies the app in a list.
    public var id: String { Self.id(for: url) }

    /// The ID an app at `url` has: its path without a trailing slash, so a URL made with and without a
    /// folder hint gives the same ID.
    public static func id(for url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// The name of the `.app` folder without the extension.
    public var fileName: String {
        let last = url.lastPathComponent
        return last.lowercased().hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    /// The name to show: display name, then bundle name, then the folder name.
    public var title: String {
        for candidate in [displayName, name] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return fileName
    }
}

/// The apps found in the application folders, and whether the list can be trusted to be complete.
public struct InstalledApps: Sendable {
    /// Every app that was found, in folder order.
    public var apps: [AppFacts]
    /// False when any folder or app could not be read in full. Name-only matches rely on this list,
    /// so an incomplete one turns them off.
    public var isComplete: Bool

    /// Creates an inventory.
    public init(apps: [AppFacts], isComplete: Bool) {
        self.apps = apps
        self.isComplete = isComplete
    }
}

/// Text rules for bundle identifiers, shared by the matcher and the eligibility check.
enum BundleIDText {
    /// Case-insensitive, Unicode-normalised form used for every comparison.
    static func fold(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Whether the identifier has at least three dot-separated, non-empty parts. Shorter ones
    /// are matched by exact equality only (`docs/UNINSTALLER.md` §3, rule 1).
    static func allowsSuffix(_ foldedID: String) -> Bool {
        let parts = foldedID.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && !parts.contains { $0.isEmpty }
    }

    /// The part after the last dot, or the whole text when there is no dot.
    static func lastComponent(_ foldedID: String) -> String {
        foldedID.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? foldedID
    }
}
