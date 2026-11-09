import Foundation

/// Why an app cannot be uninstalled (`docs/UNINSTALLER.md` §1).
public enum UninstallRefusal: Error, Sendable, Hashable {
    /// The app is under `/System`.
    case systemApp
    /// Apple's own app, by bundle ID or by signature. User-made Script Editor and Automator applets are
    /// not Apple's and are not refused for this reason (see ``UninstallEligibility/isUserMadeApplet(_:)``).
    case apple
    /// The signature could not be read, so "not Apple's" cannot be shown.
    case signatureUnknown
    /// TruongCleaner itself.
    case thisApp
    /// The app is running.
    case running
    /// Whether the app is running could not be determined.
    case runningUnknown
    /// The app has no `CFBundleIdentifier`.
    case noBundleID
    /// The app is not in `/Applications` or `~/Applications` (down to two levels).
    case outsideApplicationFolders
    /// Root or another user owns the app. Moving a folder to another parent needs write access to the
    /// folder itself, so TruongCleaner cannot move it.
    case ownedByAnotherUser
    /// The user cannot change the folder that holds the app.
    case parentNotWritable
    /// Who owns the app could not be read.
    case ownerUnknown
    /// The app could not be read.
    case unreadable

    /// A short reason for the screen.
    public var message: String {
        switch self {
        case .systemApp: "Part of macOS"
        case .apple: "Made by Apple"
        case .signatureUnknown: "Could not check who made it"
        case .thisApp: "This is TruongCleaner"
        case .running: "Running. Quit it first"
        case .runningUnknown: "Could not tell if it is running"
        case .noBundleID: "Has no app ID"
        case .outsideApplicationFolders: "Not in an Applications folder"
        case .ownedByAnotherUser: "Owned by another user (installed by an installer)"
        case .parentNotWritable: "Can't change the Applications folder"
        case .ownerUnknown: "Could not check who owns it"
        case .unreadable: "Could not be read"
        }
    }

    /// True for the two refusals that put an "Apple" badge on the row.
    public var isApple: Bool {
        self == .apple || self == .systemApp
    }
}

/// What the eligibility check and the uninstall rule need to know about this Mac and this app.
public struct UninstallContext: Sendable {
    /// The user's home folder.
    public var home: URL
    /// `/Library`. Injectable for tests.
    public var systemLibrary: URL
    /// The folders apps are installed in: `/Applications` and `~/Applications`.
    public var applicationFolders: [URL]
    /// TruongCleaner's own bundle identifier.
    public var ownBundleID: String?
    /// TruongCleaner's own `.app`.
    public var ownBundleURL: URL?
    /// The user ID of the person running the app.
    public var currentUserID: UInt32

    /// Creates a context.
    public init(
        home: URL,
        systemLibrary: URL = URL(filePath: "/Library", directoryHint: .isDirectory),
        applicationFolders: [URL],
        ownBundleID: String? = nil,
        ownBundleURL: URL? = nil,
        currentUserID: UInt32
    ) {
        self.home = home
        self.systemLibrary = systemLibrary
        self.applicationFolders = applicationFolders
        self.ownBundleID = ownBundleID
        self.ownBundleURL = ownBundleURL
        self.currentUserID = currentUserID
    }
}

/// The list of apps that must never be uninstalled. It lives in the kit, not the UI: the rule factory
/// and the finder both call it, so no caller can build an uninstall for a refused app.
public enum UninstallEligibility {
    /// The first reason `app` cannot be uninstalled, or nil when it can.
    ///
    /// - Parameters:
    ///   - app: The app and what is known about it.
    ///   - isRunning: Whether an app with this bundle ID is running. Nil when that could not be
    ///     determined, which refuses the app.
    ///   - context: This Mac's folders and TruongCleaner's own identity.
    public static func check(_ app: AppFacts, isRunning: Bool?, context: UninstallContext) -> UninstallRefusal? {
        let parts = pathParts(app.url)
        guard let parts else { return .unreadable }
        if parts.first == "System" { return .systemApp }

        let id = app.bundleID.map(BundleIDText.fold) ?? ""
        if let own = context.ownBundleID.map(BundleIDText.fold), !own.isEmpty, own == id { return .thisApp }
        if let ownURL = context.ownBundleURL, pathParts(ownURL) == parts { return .thisApp }
        if id.isEmpty { return .noBundleID }

        if app.signature == .apple { return .apple }
        if id.hasPrefix("com.apple."), !isUserMadeApplet(app) { return .apple }
        if app.signature == .unknown { return .signatureUnknown }
        if !isInsideApplicationFolders(parts, context: context) { return .outsideApplicationFolders }

        switch isRunning {
        case true?: return .running
        case nil: return .runningUnknown
        case false?: break
        }

        guard let owner = app.ownerUID, let writable = app.parentIsWritable else { return .ownerUnknown }
        if owner != context.currentUserID { return .ownedByAnotherUser }
        if !writable { return .parentNotWritable }
        return nil
    }

    /// Bundle ID prefixes that Script Editor and Automator give to the applets users save. Each ends in a
    /// dot, so Apple's own `com.apple.Automator` and `com.apple.ScriptEditor2` do not match.
    static let appletIDPrefixes = ["com.apple.scripteditor.id.", "com.apple.automator."]

    /// Whether `app` is an applet that a user made with Script Editor or Automator: its bundle ID starts
    /// with one of those prefixes followed by a name, and the signature is not Apple's (ad-hoc, Developer ID,
    /// or none). An applet is the user's own file, so it may be uninstalled. An unreadable signature is not
    /// enough: the check is then false, and the app stays refused.
    ///
    /// Leftovers of such an applet are matched by exact bundle ID evidence only (`LeftoverMatcher`).
    public static func isUserMadeApplet(_ app: AppFacts) -> Bool {
        guard app.signature == .other, let raw = app.bundleID else { return false }
        let id = BundleIDText.fold(raw)
        return appletIDPrefixes.contains { id.hasPrefix($0) && id.count > $0.count }
    }

    /// The path as components, or nil when it is not an absolute path without `.`/`..`.
    private static func pathParts(_ url: URL) -> [String]? {
        guard url.isFileURL else { return nil }
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return parts.contains(where: { $0 == "." || $0 == ".." }) ? nil : parts
    }

    /// Whether the app is a child of an application folder, or a child of a child.
    private static func isInsideApplicationFolders(_ parts: [String], context: UninstallContext) -> Bool {
        let folders = context.applicationFolders.compactMap(pathParts)
        for depth in 1...2 where parts.count > depth {
            let parent = Array(parts.dropLast(depth))
            if folders.contains(parent) { return true }
        }
        return false
    }
}
