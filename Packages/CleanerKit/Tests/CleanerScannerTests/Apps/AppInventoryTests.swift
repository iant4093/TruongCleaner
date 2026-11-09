import CleanerCore
import CleanerTestSupport
import Darwin
import Foundation
import Testing

@testable import CleanerScanner

struct AppInventoryTests {
    @Test func listsAppsInBothFoldersAndOneLevelDown() async throws {
        try await withAppsHarness { harness in
            try harness.addApp(file: "Alpha", bundleID: "com.example.Alpha")
            try harness.addApp("Applications/Vendor", file: "Beta", bundleID: "com.example.Beta")
            try harness.addApp("home/Applications", file: "Gamma", bundleID: "com.example.Gamma")
            // Three levels down is outside the scope.
            try harness.addApp("Applications/Vendor/Deep", file: "Delta", bundleID: "com.example.Delta")

            let inventory = await harness.inventory()
            #expect(inventory.apps.compactMap(\.bundleID) == ["com.example.Alpha", "com.example.Beta", "com.example.Gamma"])
            #expect(inventory.isComplete)
        }
    }

    @Test func readsTheFactsFromInfoPlistAndTheFolder() async throws {
        try await withAppsHarness { harness in
            let url = try harness.addApp(file: "Alpha", bundleID: "com.example.Alpha", name: "Alpha Name", executable: "alpha-bin")
            try harness.writePlist(
                "Applications/Alpha.app/Contents/Info.plist",
                [
                    "CFBundleIdentifier": "com.example.Alpha", "CFBundleName": "Alpha Name",
                    "CFBundleDisplayName": "Alpha Display", "CFBundleExecutable": "alpha-bin",
                    "CFBundleShortVersionString": "3.4.5", "CFBundleVersion": "99",
                ])
            let app = try harness.app("com.example.Alpha", in: await harness.inventory())
            #expect(app.url.lastPathComponent == "Alpha.app")
            #expect(app.url.deletingLastPathComponent().lastPathComponent == "Applications")
            #expect(app.name == "Alpha Name")
            #expect(app.displayName == "Alpha Display")
            #expect(app.executableName == "alpha-bin")
            #expect(app.version == "3.4.5")
            #expect(app.title == "Alpha Display")
            #expect(app.fileName == "Alpha")
            #expect(app.ownerUID == UInt32(getuid()))
            #expect(app.parentIsWritable == true)
            _ = url
        }
    }

    @Test func anUnsignedAppIsNotAppleAndHasNoTeam() async throws {
        try await withAppsHarness { harness in
            try harness.addApp(file: "Alpha", bundleID: "com.example.Alpha")
            let app = try harness.app("com.example.Alpha", in: await harness.inventory())
            #expect(app.signature == .other)
            #expect(app.teamID == nil)
        }
    }

    @Test func versionFallsBackToTheBuildNumber() async throws {
        try await withAppsHarness { harness in
            try harness.writePlist(
                "Applications/Alpha.app/Contents/Info.plist",
                ["CFBundleIdentifier": "com.example.Alpha", "CFBundleVersion": "42"])
            let app = try harness.app("com.example.Alpha", in: await harness.inventory())
            #expect(app.version == "42")
            #expect(app.title == "Alpha")
        }
    }

    @Test func aSymbolicLinkToAnAppIsNotFollowedOrListed() async throws {
        try await withAppsHarness { harness in
            let real = try harness.addApp("home", file: "Hidden", bundleID: "com.example.Hidden")
            try harness.tree.addSymlink("Applications/Linked.app", destination: real)
            try harness.tree.addSymlink("Applications/Vendor", destination: harness.home)

            let inventory = await harness.inventory()
            #expect(inventory.apps.isEmpty)
            #expect(inventory.isComplete)
        }
    }

    @Test func aMissingFolderCountsAsEmptyAndComplete() async throws {
        try await withAppsHarness { harness in
            try harness.addApp(file: "Alpha", bundleID: "com.example.Alpha")
            let inventory = await AppInventory.scan(folders: harness.folders + [harness.tree.url(for: "nowhere")])
            #expect(inventory.apps.count == 1)
            #expect(inventory.isComplete)
        }
    }

    @Test func anAppWithoutInfoPlistMakesTheInventoryIncomplete() async throws {
        try await withAppsHarness { harness in
            try harness.addApp(file: "Alpha", bundleID: "com.example.Alpha")
            try harness.tree.addDirectory("Applications/Broken.app")
            let inventory = await harness.inventory()
            #expect(!inventory.isComplete)
            // The good app is still listed, and the broken one is listed without an ID.
            #expect(inventory.apps.count == 2)
            #expect(inventory.apps.first { $0.fileName == "Broken" }?.bundleID == nil)
        }
    }

    @Test func aMalformedOrOversizedInfoPlistMakesTheInventoryIncomplete() async throws {
        try await withAppsHarness { harness in
            let plist = try harness.tree.addFile("Applications/Bad.app/Contents/Info.plist", size: 0)
            try Data("not a plist".utf8).write(to: plist)
            #expect(!(await harness.inventory()).isComplete)

            let big = try harness.tree.addFile("Applications/Big.app/Contents/Info.plist", size: 2 * 1024 * 1024)
            _ = big
            #expect(!(await harness.inventory()).isComplete)
        }
    }

    @Test func aFolderThatCannotBeReadMakesTheInventoryIncomplete() async throws {
        try await withAppsHarness { harness in
            try harness.addApp(file: "Alpha", bundleID: "com.example.Alpha")
            try harness.tree.addDirectory("Applications/Locked")
            try harness.tree.setPermissions("Applications/Locked", mode: 0o000)
            let inventory = await harness.inventory()
            #expect(!inventory.isComplete)
            #expect(inventory.apps.map(\.bundleID) == ["com.example.Alpha"])
        }
    }

    @Test func appsAreSortedByTheirDisplayedName() async throws {
        try await withAppsHarness { harness in
            try harness.addApp(file: "zeta", bundleID: "com.example.zeta")
            try harness.addApp(file: "Alpha", bundleID: "com.example.Alpha")
            try harness.addApp(file: "beta", bundleID: "com.example.beta")
            #expect((await harness.inventory()).apps.map(\.title) == ["Alpha", "beta", "zeta"])
        }
    }

    @Test func defaultFoldersAreApplicationsAndHomeApplications() {
        let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
        let folders = AppInventory.defaultFolders(home: home).map { $0.path(percentEncoded: false) }
        #expect(folders == ["/Applications/", "/Users/test/Applications/"])
    }

    // MARK: Signatures

    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/System/Applications/Calculator.app")))
    func anAppleAppIsRecognisedByItsSignature() {
        // Read-only look at a system app. No file is changed.
        let info = AppSigning.read(URL(filePath: "/System/Applications/Calculator.app", directoryHint: .isDirectory))
        #expect(info.signature == .apple)
    }

    @Test func aFolderThatIsNotABundleHasAnUnknownOrUnsignedSignature() throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let url = try tree.addDirectory("Empty.app")
        let info = AppSigning.read(url)
        #expect(info.signature != .apple)
    }

    // MARK: Sizes

    @Test func sizesAreMeasuredPerAppAndNeverBelowTheContents() async throws {
        try await withAppsHarness { harness in
            let small = try harness.addApp(file: "Small", bundleID: "com.example.Small", size: 10_000)
            let large = try harness.addApp(file: "Large", bundleID: "com.example.Large", size: 400_000)
            let sizer = AppSizer()
            async let first = sizer.size(of: small)
            async let second = sizer.size(of: large)
            let (smallSize, largeSize) = await (first, second)

            #expect(smallSize.appID == AppFacts.id(for: small))
            let smallBytes = try #require(smallSize.allocatedBytes)
            let largeBytes = try #require(largeSize.allocatedBytes)
            #expect(smallBytes >= 10_000)
            #expect(largeBytes >= 400_000)
            #expect(largeBytes > smallBytes)
            #expect(!smallSize.isPartial)
        }
    }

    @Test func manyQueuedSizesAllFinish() async throws {
        try await withAppsHarness { harness in
            var urls: [URL] = []
            for index in 0..<12 {
                urls.append(try harness.addApp(file: "App\(index)", bundleID: "com.example.App\(index)", size: 1_000))
            }
            let sizer = AppSizer(maxConcurrentWalks: 99)
            let sizes = await withTaskGroup(of: AppSize.self) { group in
                for url in urls { group.addTask { await sizer.size(of: url) } }
                var all: [AppSize] = []
                for await size in group { all.append(size) }
                return all
            }
            #expect(sizes.count == 12)
            #expect(sizes.allSatisfy { $0.allocatedBytes != nil })
        }
    }

    @Test func anAppThatVanishedHasAnUnknownSizeNotZero() async throws {
        try await withAppsHarness { harness in
            let size = await AppSizer().size(of: harness.tree.url(for: "Applications/Gone.app"))
            #expect(size.allocatedBytes == nil)
            #expect(size.isPartial)
        }
    }

    @Test func aFolderMacOSRefusesGivesAPartialSize() async throws {
        try await withAppsHarness { harness in
            let app = try harness.addApp(file: "Alpha", bundleID: "com.example.Alpha")
            try harness.tree.addFile("Applications/Alpha.app/Contents/Resources/secret.bin", size: 5_000)
            try harness.tree.setPermissions("Applications/Alpha.app/Contents/Resources", mode: 0o000)
            let size = await AppSizer().size(of: app)
            #expect(size.isPartial)
            #expect(size.allocatedBytes != nil)
        }
    }
}
