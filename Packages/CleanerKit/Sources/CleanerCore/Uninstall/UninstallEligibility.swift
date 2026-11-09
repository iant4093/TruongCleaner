import Foundation

/// Why an app cannot be uninstalled (`docs/UNINSTALLER.md` §1).
public enum UninstallRefusal: Error, Sendable, Hashable {
    /// The app is under `/System`.
    case systemApp
    /// Apple's own app, by bundle ID or by signature.
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
    /// Another user or root owns the app, or the user cannot change its folder.
    case needsAdministrator
    /// Who owns the app could not be read.
    case ownerUnknown
    /// The app could not be read.
    case unreadable

    /// A short reason for the screen.
    public var message: String {
        switch self {
        case .systemApp: "Part of macOS"
        case .apple: "Apple app"
        case .signatureUnknown: "Could not check who made it"
        case .thisApp: "This is TruongCleaner"
        case .running: "Running. Quit it first"
        case .runningUnknown: "Could not tell if it is running"
        case .noBundleID: "Has no app ID"
        case .outsideApplicationFolders: "Not in an Applications folder"
        case .needsAdministrator: "Needs an administrator"
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

        if id.hasPrefix("com.apple.") || app.signature == .apple { return .apple }
        if app.signature == .unknown { return .signatureUnknown }
        if !isInsideApplicationFolders(parts, context: context) { return .outsideApplicationFolders }

        switch isRunning {
        case true?: return .running
        case nil: return .runningUnknown
        case false?: break
        }

        guard let owner = app.ownerUID, let writable = app.parentIsWritable else { return .ownerUnknown }
        if owner != context.currentUserID || !writable { return .needsAdministrator }
        return nil
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
