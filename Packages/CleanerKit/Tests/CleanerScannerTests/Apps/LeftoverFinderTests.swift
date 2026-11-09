import CleanerCore
import CleanerTestSupport
import Darwin
import Foundation
import Testing

@testable import CleanerScanner

/// The finder on a fixture home and a fixture `/Applications`. Nothing reads the real Library.
struct LeftoverFinderTests {
    private static let containerUUID = "6F1B0C52-0000-4000-8000-0123456789AB"

    /// Runs the finder for the app `com.example.Foo` (installed as `Foo.app`, called "Foo Tool").
    private func find(
        _ harness: AppsHarness, isRunning: Bool? = false, complete: Bool? = nil
    ) async throws -> UninstallReport {
        let inventory = await harness.inventory()
        let app = try harness.app("com.example.Foo", in: inventory)
        let effective = complete.map { InstalledApps(apps: inventory.apps, isComplete: $0) } ?? inventory
        let result = await LeftoverFinder.find(
            for: app, inventory: effective, isRunning: isRunning, context: harness.context())
        return try result.get()
    }

    private func addFoo(_ harness: AppsHarness) throws {
        try harness.addApp(file: "Foo", bundleID: "com.example.Foo", name: "Foo Tool", executable: "FooTool")
    }

    private func relativePaths(_ report: UninstallReport, _ harness: AppsHarness) -> [String] {
        let root = Self.withoutSlash(harness.tree.root.path(percentEncoded: false))
        return report.leftovers.map {
            String(Self.withoutSlash($0.finding.url.path(percentEncoded: false)).dropFirst(root.count + 1))
        }
    }

    private static func withoutSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    // MARK: Where it looks (§2)

    @Test func findsAnItemInEverySearchedFolder() async throws {
        try await withAppsHarness { harness in
            try addFoo(harness)
            let tree = harness.tree
            try tree.addFile("home/Library/Application Support/Foo Tool/data.db", size: 100)
            try tree.addFile("home/Library/Caches/com.example.Foo/blob", size: 100)
            try tree.addFile("home/Library/Preferences/com.example.Foo.plist", size: 100)
            try tree.addFile("home/Library/Preferences/ByHost/com.example.Foo.0123ABCD.plist", size: 100)
            try tree.addFile("home/Library/Saved Application State/com.example.Foo.savedState/windows.plist", size: 100)
            try tree.addFile("home/Library/HTTPStorages/com.example.Foo/x", size: 100)
            try tree.addFile("home/Library/WebKit/com.example.Foo/x", size: 100)
            try tree.addFile("home/Library/Logs/Foo Tool/log.txt", size: 100)
            try tree.addFile("home/Library/Application Scripts/com.example.Foo/s.scpt", size: 100)
            try tree.addFile("home/Library/Cookies/com.example.Foo.binarycookies", size: 100)
            try tree.addFile("home/Library/Containers/com.example.Foo/Data/x", size: 100)
            try tree.addFile("home/Library/Group Containers/group.com.example.Foo/x", size: 100)
            try harness.writePlist(
                "home/Library/LaunchAgents/com.example.Foo.agent.plist",
                ["Label": "com.example.Foo.agent", "ProgramArguments": [tree.url(for: "Applications/Foo.app/Contents/MacOS/FooTool").path]])

            let report = try await find(harness)
            #expect(Set(relativePaths(report, harness)) == [
                "home/Library/Application Support/Foo Tool", "home/Library/Caches/com.example.Foo",
                "home/Library/Preferences/com.example.Foo.plist",
                "home/Library/Preferences/ByHost/com.example.Foo.0123ABCD.plist",
                "home/Library/Saved Application State/com.example.Foo.savedState",
                "home/Library/HTTPStorages/com.example.Foo", "home/Library/WebKit/com.example.Foo",
                "home/Library/Logs/Foo Tool", "home/Library/Application Scripts/com.example.Foo",
                "home/Library/Cookies/com.example.Foo.binarycookies",
                "home/Library/Containers/com.example.Foo", "home/Library/Group Containers/group.com.example.Foo",
                "home/Library/LaunchAgents/com.example.Foo.agent.plist",
            ])
            let tiers = Dictionary(report.leftovers.map { ($0.name, $0.tier) }, uniquingKeysWith: { first, _ in first })
            #expect(tiers["Foo Tool"] == .review)
            #expect(tiers["group.com.example.Foo"] == .review)
            #expect(tiers["com.example.Foo"] == .safe)
            #expect(tiers["com.example.Foo.agent.plist"] == .safe)
            #expect(report.leftovers.allSatisfy { $0.finding.ruleID == "apps.uninstall" })
        }
    }

    @Test func incident_pearcleaner587_documentsAndPersonalFoldersAreNeverSearched() async throws {
        try await withAppsHarness { harness in
            try addFoo(harness)
            let tree = harness.tree
            // Names that would match, in places that must never be searched.
            for folder in ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", ".config", ".local/share", "Library/Mobile Documents", "Library/CloudStorage"] {
                try tree.addFile("home/\(folder)/Foo Tool/keep.txt", size: 100)
                try tree.addFile("home/\(folder)/com.example.Foo/keep.txt", size: 100)
                try tree.addFile("home/\(folder)/com.example.Foo.plist", size: 100)
            }
            try tree.addFile("home/Foo Tool/keep.txt", size: 100)
            try tree.addFile("home/com.example.Foo/keep.txt", size: 100)
            try tree.addFile("home/Library/Foo Tool/keep.txt", size: 100)
            // And one real leftover, to show the finder does search.
            try tree.addFile("home/Library/Caches/com.example.Foo/x", size: 100)

            let report = try await find(harness)
            #expect(relativePaths(report, harness) == ["home/Library/Caches/com.example.Foo"])
            #expect(report.systemItems.isEmpty)
        }
    }

    @Test func onlyDirectChildrenOfTheSearchedFoldersAreOffered() async throws {
        try await withAppsHarness { harness in
            try addFoo(harness)
            // Two levels down never matches, even with a perfect name.
            try harness.tree.addFile("home/Library/Application Support/Vendor/com.example.Foo/x", size: 10)
            try harness.tree.addFile("home/Library/Caches/Vendor/Foo Tool/x", size: 10)
            #expect(try await find(harness).leftovers.isEmpty)
        }
    }

    @Test func symbolicLinksAreNeverFollowedOrOffered() async throws {
        try await withAppsHarness { harness in
            try addFoo(harness)
            let precious = try harness.tree.addFile("precious/keep.txt", size: 100)
            let preciousFolder = precious.deletingLastPathComponent()
            // A matching name that is a link.
            try harness.tree.addDirectory("home/Library/Caches")
            try harness.tree.addSymlink("home/Library/Caches/com.example.Foo", destination: preciousFolder)
            try harness.tree.addSymlink("home/Library/Preferences/com.example.Foo.plist", destination: precious)
            // A searched folder that is a link is not entered.
            try harness.tree.addSymlink("home/Library/Logs", destination: preciousFolder)

            let report = try await find(harness)
            #expect(report.leftovers.isEmpty)
            #expect(FileManager.default.fileExists(atPath: precious.path(percentEncoded: false)))
        }
    }

    // MARK: Containers

    @Test func containersAreMatchedByTheirMetadataIdentifier() async throws {
        try await withAppsHarness { harness in
            try addFoo(harness)
            let other = "7F1B0C52-0000-4000-8000-0123456789AB"
            let bare = "8F1B0C52-0000-4000-8000-0123456789AB"
            try harness.tree.addFile("home/Library/Containers/\(Self.containerUUID)/Data/x", size: 100)
            try harness.writePlist(
                "home/Library/Containers/\(Self.containerUUID)/.com.apple.containermanagerd.metadata.plist",
                ["MCMMetadataIdentifier": "com.example.Foo"])
            try harness.tree.addFile("home/Library/Containers/\(other)/Data/x", size: 100)
            try harness.writePlist(
                "home/Library/Containers/\(other)/.com.apple.containermanagerd.metadata.plist",
                ["MCMMetadataIdentifier": "com.example.Bar"])
            try harness.tree.addFile("home/Library/Containers/\(bare)/Data/x", size: 100)

            let report = try await find(harness)
            #expect(report.leftovers.map(\.name) == [Self.containerUUID])
            #expect(report.leftovers.first?.tier == .safe)
            if case .containerMetadata? = report.leftovers.first?.evidence {} else { Issue.record("wrong evidence") }
        }
    }

    @Test func aContainerRecordThatIsTooBigOrBrokenGivesNoMatch() async throws {
        try await withAppsHarness { harness in
            try addFoo(harness)
            let big = "7F1B0C52-0000-4000-8000-0123456789AB"
            let broken = "8F1B0C52-0000-4000-8000-0123456789AB"
            let link = "9F1B0C52-0000-4000-8000-0123456789AB"
            // Valid XML padded past the 256 KB cap.
            let padding = String(repeating: " ", count: 300 * 1024)
            let xml = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>MCMMetadataIdentifier</key><string>com.example.Foo</string></dict>\(padding)</plist>"
            let bigRecord = try harness.tree.addFile("home/Library/Containers/\(big)/.com.apple.containermanagerd.metadata.plist", size: 0)
            try Data(xml.utf8).write(to: bigRecord)
            let brokenRecord = try harness.tree.addFile("home/Library/Containers/\(broken)/.com.apple.containermanagerd.metadata.plist", size: 0)
            try Data("junk".utf8).write(to: brokenRecord)
            // A record that is a link is never read.
            let target = try harness.writePlist("elsewhere/record.plist", ["MCMMetadataIdentifier": "com.example.Foo"])
            try harness.tree.addDirectory("home/Library/Containers/\(link)")
            try harness.tree.addSymlink("home/Library/Containers/\(link)/.com.apple.containermanagerd.metadata.plist", destination: target)

            #expect(try await find(harness).leftovers.isEmpty)
        }
    }

    @Test func containersNamedByABundleIDAreMatchedByNameWithoutReadingTheirRecord() async throws {
        try await withAppsHarness { harness in
            try addFoo(harness)
            try harness.tree.addFile("home/Library/Containers/com.example.Foo/Data/x", size: 100)
            try harness.tree.addFile("home/Library/Containers/com.example.Foo.Widget/Data/x", size: 100)
            let report = try await find(harness)
            #expect(Set(report.leftovers.map(\.name)) == ["com.example.Foo", "com.example.Foo.Widget"])
        }
    }

    // MARK: Launch agents

    @Test func aLaunchAgentNeedsBothALabelAndAProgramInsideTheApp() async throws {
        try await withAppsHarness { harness in
            try addFoo(harness)
            let program = harness.tree.url(for: "Applications/Foo.app/Contents/MacOS/FooTool").path(percentEncoded: false)
            try harness.writePlist("home/Library/LaunchAgents/good.plist", ["Label": "com.example.Foo.good", "Program": program])
            try harness.writePlist("home/Library/LaunchAgents/com.example.Foo.elsewhere.plist", ["Label": "com.example.Foo.elsewhere", "ProgramArguments": ["/usr/local/bin/foo"]])
            try harness.writePlist("home/Library/LaunchAgents/com.example.Foo.other.plist", ["Label": "com.other.Bar", "ProgramArguments": [program]])
            try harness.writePlist("home/Library/LaunchAgents/nolabel.plist", ["ProgramArguments": [program]])
            let junk = try harness.tree.addFile("home/Library/LaunchAgents/com.example.Foo.junk.plist", size: 0)
            try Data("junk".utf8).write(to: junk)

            let report = try await find(harness)
            #expect(report.leftovers.map(\.name) == ["good.plist"])
        }
    }

    // MARK: Names and the inventory (§3)

    @Test func nameOnlyMatchesAreDroppedWhenTheInventoryIsIncomplete() async throws {
        try await withAppsHarness { harness in
            try addFoo(harness)
            try harness.tree.addFile("home/Library/Application Support/Foo Tool/x", size: 100)
            try harness.tree.addFile("home/Library/Caches/com.example.Foo/x", size: 100)

            #expect(try await find(harness, complete: true).leftovers.count == 2)
            let report = try await find(harness, complete: false)
            #expect(report.leftovers.map(\.name) == ["com.example.Foo"])
            #expect(report.notice != nil)
        }
    }

    @Test func nameOnlyMatchesAreDroppedWhenTheInventoryCouldNotBeRead() async throws {
        try await withAppsHarness { harness in
            try addFoo(harness)
            try harness.tree.addDirectory("Applications/Locked")
            try harness.tree.setPermissions("Applications/Locked", mode: 0o000)
            try harness.tree.addFile("home/Library/Application Support/Foo Tool/x", size: 100)
            try harness.tree.addFile("home/Library/Caches/com.example.Foo/x", size: 100)

            let report = try await find(harness)
            #expect(report.leftovers.map(\.name) == ["com.example.Foo"])
        }
    }

    @Test func incident_pearcleaner506_aNameSharedWithAnotherInstalledAppIsDropped() async throws {
        try await withAppsHarness { harness in
            try addFoo(harness)
            // Another installed app is also called "Foo Tool", so the folder may be its own.
            try harness.addApp(file: "Foo Tool", bundleID: "com.rival.FooTool", name: "Foo Tool", executable: "rival")
            try harness.tree.addFile("home/Library/Application Support/Foo Tool/x", size: 100)
            try harness.tree.addFile("home/Library/Caches/com.example.Foo/x", size: 100)
            #expect(try await find(harness).leftovers.map(\.name) == ["com.example.Foo"])
        }
    }

    @Test func aFolderHoldingAnotherAppsBundleIDIsDropped() async throws {
        try await withAppsHarness { harness in
            try addFoo(harness)
            try harness.addApp(file: "Bar", bundleID: "com.other.Bar")
            try harness.tree.addFile("home/Library/Application Support/Foo Tool/com.other.Bar.helper/x", size: 100)
            try harness.tree.addFile("home/Library/Application Support/com.example.Foo/data", size: 100)
            #expect(try await find(harness).leftovers.map(\.name) == ["com.example.Foo"])
        }
    }

    @Test func aFolderThatCannotBeListedIsKeptOnlyWithBundleIDEvidence() async throws {
        try await withAppsHarness { harness in
            try addFoo(harness)
            try harness.tree.addFile("home/Library/Application Support/Foo Tool/x", size: 100)
            try harness.tree.addFile("home/Library/Application Support/com.example.Foo/x", size: 100)
            try harness.tree.addFile("home/Library/Caches/com.example.Foo/x", size: 100)
            try harness.tree.setPermissions("home/Library/Application Support/Foo Tool", mode: 0o000)
            try harness.tree.setPermissions("home/Library/Application Support/com.example.Foo", mode: 0o000)

            let report = try await find(harness)
            // The name-only folder cannot be checked for other apps' IDs, so it is not offered. The one with
            // bundle-ID evidence passes the check but cannot be measured, so it is counted, not shown as 0 bytes.
            #expect(report.leftovers.map(\.name) == ["com.example.Foo"])
            #expect(report.leftovers.first?.finding.url.path(percentEncoded: false).contains("/Caches/") == true)
            #expect(report.unmeasuredCount == 1)
        }
    }

    // MARK: Sizes and identity

    @Test func findingsCarryTheIdentityAndSizeOfWhatWasScanned() async throws {
        try await withAppsHarness { harness in
            try addFoo(harness)
            let file = try harness.tree.addFile("home/Library/Preferences/com.example.Foo.plist", size: 10_000)
            let folder = try harness.tree.addDirectory("home/Library/Caches/com.example.Foo")
            try harness.tree.addFile("home/Library/Caches/com.example.Foo/a.bin", size: 50_000)
            try harness.tree.addFile("home/Library/Caches/com.example.Foo/b.bin", size: 50_000)

            let report = try await find(harness)
            let fileFinding = try #require(report.leftovers.first { $0.name == "com.example.Foo.plist" }).finding
            let folderFinding = try #require(report.leftovers.first { $0.name == "com.example.Foo" }).finding

            var fileInfo = stat()
            #expect(lstat(file.path(percentEncoded: false), &fileInfo) == 0)
            #expect(fileFinding.fileID == UInt64(fileInfo.st_ino))
            #expect(fileFinding.allocatedBytes >= 10_000)
            #expect(!fileFinding.isDirectory)
            #expect(fileFinding.itemCount == 1)

            var folderInfo = stat()
            #expect(lstat(folder.path(percentEncoded: false), &folderInfo) == 0)
            #expect(folderFinding.fileID == UInt64(folderInfo.st_ino))
            #expect(folderFinding.allocatedBytes >= 100_000)
            #expect(folderFinding.isDirectory)
            #expect(folderFinding.itemCount == 3)
            #expect(folderFinding.fsid == fileFinding.fsid)
        }
    }

    @Test func theBundleIsAFindingWithItsOwnSize() async throws {
        try await withAppsHarness { harness in
            try harness.addApp(file: "Foo", bundleID: "com.example.Foo", name: "Foo Tool", executable: "FooTool", size: 200_000)
            let report = try await find(harness)
            #expect(report.bundle.url.lastPathComponent == "Foo.app")
            #expect(report.bundle.isDirectory)
            #expect(report.bundle.allocatedBytes >= 200_000)
            #expect(report.bundle.ruleID == "apps.uninstall")
            #expect(report.setup.rule.id == "apps.uninstall")
            #expect(report.setup.expandedRoots.contains { $0.path(percentEncoded: false) == harness.applications.path(percentEncoded: false) + "/" })
        }
    }

    @Test func aFolderMacOSRefusesToOpenIsReportedNotCountedAsEmpty() async throws {
        try await withAppsHarness { harness in
            try addFoo(harness)
            try harness.tree.addFile("home/Library/Caches/com.example.Foo/x", size: 100)
            try harness.tree.addFile("home/Library/Application Support/Other/x", size: 100)
            try harness.tree.setPermissions("home/Library/Application Support", mode: 0o000)
            let report = try await find(harness)
            #expect(report.leftovers.map(\.name) == ["com.example.Foo"])
            #expect(report.unreadablePlaces == [UnreadablePlace(place: LeftoverPlace(scope: .user, folder: .applicationSupport), needsAccess: true)])
        }
    }

    @Test func aMatchInsideAFolderThatCannotBeFullyReadIsMarkedAtLeast() async throws {
        try await withAppsHarness { harness in
            try addFoo(harness)
            try harness.tree.addFile("home/Library/Caches/com.example.Foo/open.bin", size: 100)
            try harness.tree.addFile("home/Library/Caches/com.example.Foo/locked/x", size: 100)
            try harness.tree.setPermissions("home/Library/Caches/com.example.Foo/locked", mode: 0o000)
            let report = try await find(harness)
            #expect(report.leftovers.first?.sizeIsAtLeast == true)
        }
    }

    // MARK: /Library (information only)

    @Test func libraryItemsAreInformationOnlyAndNeverFindings() async throws {
        try await withAppsHarness { harness in
            try addFoo(harness)
            let tree = harness.tree
            try tree.addFile("Library/Application Support/com.example.Foo/x", size: 100)
            try tree.addFile("Library/Caches/Foo Tool/x", size: 100)
            try tree.addFile("Library/PrivilegedHelperTools/com.example.Foo.helper", size: 100)
            try harness.writePlist("Library/LaunchDaemons/com.example.Foo.helper.plist", ["Label": "com.example.Foo.helper", "Program": "/Library/PrivilegedHelperTools/com.example.Foo.helper"])
            try tree.addFile("Library/Application Support/com.example.Bar/x", size: 100)

            let report = try await find(harness)
            #expect(report.leftovers.isEmpty)
            #expect(Set(report.systemItems.map { $0.url.lastPathComponent }) == [
                "com.example.Foo", "Foo Tool", "com.example.Foo.helper", "com.example.Foo.helper.plist",
            ])
            #expect(report.systemItems.allSatisfy { $0.allocatedBytes != nil })
            // None of them is a root of the uninstall rule.
            let roots = report.setup.expandedRoots.map { $0.path(percentEncoded: false) }
            #expect(!roots.contains { $0.hasPrefix(harness.systemLibrary.path(percentEncoded: false)) })
        }
    }

    // MARK: Refusals

    @Test func incident_mole1854_aRunningAppGetsNoReport() async throws {
        try await withAppsHarness { harness in
            try addFoo(harness)
            let inventory = await harness.inventory()
            let app = try harness.app("com.example.Foo", in: inventory)
            for (running, refusal) in [(true, UninstallRefusal.running), (nil, .runningUnknown)] as [(Bool?, UninstallRefusal)] {
                let result = await LeftoverFinder.find(for: app, inventory: inventory, isRunning: running, context: harness.context())
                if case .failure(let reason) = result { #expect(reason == refusal) } else { Issue.record("a report was made") }
            }
        }
    }

    @Test func incident_pearcleaner618_anAppleAppGetsNoReport() async throws {
        try await withAppsHarness { harness in
            try harness.addApp(file: "Notes", bundleID: "com.apple.Notes")
            try harness.tree.addFile("home/Library/Containers/com.apple.Notes/x", size: 100)
            let inventory = await harness.inventory()
            let app = try harness.app("com.apple.Notes", in: inventory)
            let result = await LeftoverFinder.find(for: app, inventory: inventory, isRunning: false, context: harness.context())
            if case .failure(let reason) = result { #expect(reason == .apple) } else { Issue.record("a report was made") }
        }
    }

    @Test func theFinderNeverChangesAnything() async throws {
        try await withAppsHarness { harness in
            try addFoo(harness)
            try harness.tree.addFile("home/Library/Caches/com.example.Foo/x", size: 100)
            let before = try listing(harness.tree.root)
            _ = try await find(harness)
            #expect(try listing(harness.tree.root) == before)
        }
    }

    private func listing(_ root: URL) throws -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: root.path(percentEncoded: false))
        return (enumerator?.allObjects as? [String] ?? []).sorted()
    }
}
