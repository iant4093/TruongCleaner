import Foundation

@testable import CleanerCore

/// Builders for the uninstaller's pure tests. No file system.
enum UninstallFixtures {
    /// An app. Defaults describe `Foo Tool`, a third-party app in `/Applications` that the user owns.
    static func app(
        _ bundleID: String? = "com.example.Foo",
        name: String? = "Foo Tool",
        displayName: String? = nil,
        executable: String? = "FooTool",
        team: String? = "ABCDE12345",
        signature: AppSignature = .other,
        path: String = "/Applications/Foo.app",
        owner: UInt32? = 501,
        writable: Bool? = true
    ) -> AppFacts {
        AppFacts(
            url: URL(filePath: path, directoryHint: .isDirectory),
            bundleID: bundleID,
            name: name,
            displayName: displayName,
            executableName: executable,
            version: "1.0",
            teamID: team,
            signature: signature,
            ownerUID: owner,
            parentIsWritable: writable
        )
    }

    /// Another installed app. `name` also becomes its executable name unless given.
    static func other(
        _ bundleID: String, name: String, executable: String? = nil, team: String? = "ZZZZZ99999"
    ) -> AppFacts {
        app(
            bundleID, name: name, executable: executable ?? name, team: team,
            path: "/Applications/\(name).app")
    }

    static func user(_ folder: LeftoverFolder) -> LeftoverPlace {
        LeftoverPlace(scope: .user, folder: folder)
    }

    static func system(_ folder: LeftoverFolder) -> LeftoverPlace {
        LeftoverPlace(scope: .system, folder: folder)
    }

    /// Matches `target` against listings. The inventory is `target` plus `others`.
    static func match(
        _ target: AppFacts,
        others: [AppFacts] = [],
        complete: Bool = true,
        _ listings: [LeftoverPlace: [LeftoverEntry]],
        children: @escaping (LeftoverPlace, String) -> [String]? = { _, _ in [] }
    ) -> LeftoverMatches {
        LeftoverMatcher.match(
            app: target,
            inventory: InstalledApps(apps: [target] + others, isComplete: complete),
            listings: listings,
            childNames: children)
    }

    /// Names of the candidates, in the order the matcher returned them.
    static func names(_ matches: LeftoverMatches) -> [String] {
        matches.candidates.map(\.name)
    }

    static func context(
        applicationFolders: [URL] = [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            URL(filePath: "/Users/test/Applications", directoryHint: .isDirectory),
        ],
        ownBundleID: String? = "com.iant4093.TruongCleaner",
        ownBundleURL: URL? = nil,
        userID: UInt32 = 501
    ) -> UninstallContext {
        UninstallContext(
            home: URL(filePath: "/Users/test", directoryHint: .isDirectory),
            applicationFolders: applicationFolders,
            ownBundleID: ownBundleID,
            ownBundleURL: ownBundleURL,
            currentUserID: userID)
    }
}
