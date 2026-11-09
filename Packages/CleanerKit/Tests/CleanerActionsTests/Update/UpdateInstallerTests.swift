import CleanerTestSupport
import Foundation
import Testing

@testable import CleanerActions

struct UpdateInstallerTests {
    /// A fixture "Applications" folder with the running app (build 1000) in it, and a verified
    /// new app (build 2000) elsewhere in the tree.
    private struct Setup {
        let applications: URL
        let running: URL
        let new: URL
    }

    private func makeSetup(_ tree: FixtureTree) throws -> Setup {
        try tree.addDirectory("Applications")
        var old = FixtureApp.Spec()
        old.build = 1000
        let running = try FixtureApp.make(in: tree, at: "Applications/TruongCleaner.app", old)
        let new = try FixtureApp.make(in: tree, at: "staging/TruongCleaner.app")
        return Setup(applications: tree.url(for: "Applications"), running: running, new: new)
    }

    private func names(in folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
    }

    // MARK: Swap

    @Test func swap_putsTheNewAppAtTheOldPathAndKeepsTheOldOneAside() async throws {
        try await withUpdateTree { tree in
            let setup = try makeSetup(tree)
            let installer = UpdateInstaller(allowedParents: [setup.applications])

            let aside = try installer.swap(running: setup.running, new: setup.new)

            #expect(FixtureApp.build(of: setup.running) == 2000)
            #expect(FixtureApp.build(of: aside) == 1000)
            #expect(UpdateWorkspace.unixPath(aside.deletingLastPathComponent()) == UpdateWorkspace.unixPath(setup.applications))
            #expect(aside.lastPathComponent.hasPrefix(".TruongCleaner-old-"))
            #expect(aside.lastPathComponent.hasSuffix(".app"))
            #expect(UpdateCleanup.isOldBundleName(aside.lastPathComponent))
            #expect(!FileManager.default.fileExists(atPath: setup.new.path(percentEncoded: false)))
            #expect(names(in: setup.applications) == ["TruongCleaner.app", aside.lastPathComponent])
        }
    }

    @Test func swap_putsTheOldAppBackWhenMovingTheNewOneFails() async throws {
        try await withUpdateTree { tree in
            let setup = try makeSetup(tree)
            // Move 1 (old aside) works; move 2 (new into place) fails.
            let installer = UpdateInstaller(
                files: FlakyFileOperations(failingMoves: [2]), allowedParents: [setup.applications])

            let error = try #require(throws: UpdateError.self) {
                try installer.swap(running: setup.running, new: setup.new)
            }
            guard case .swapFailed(_, let restored) = error else {
                Issue.record("Expected swapFailed, got \(error)")
                return
            }
            #expect(restored)
            #expect(FixtureApp.build(of: setup.running) == 1000)
            #expect(names(in: setup.applications) == ["TruongCleaner.app"])
            // The new app was not consumed.
            #expect(FixtureApp.build(of: setup.new) == 2000)
        }
    }

    @Test func swap_removesAHalfCopiedAppBeforeRollingBack() async throws {
        try await withUpdateTree { tree in
            let setup = try makeSetup(tree)
            let installer = UpdateInstaller(
                files: FlakyFileOperations(failingMoves: [2], leavePartialCopy: true),
                allowedParents: [setup.applications])

            #expect(throws: UpdateError.self) {
                try installer.swap(running: setup.running, new: setup.new)
            }
            #expect(FixtureApp.build(of: setup.running) == 1000)
            #expect(names(in: setup.applications) == ["TruongCleaner.app"])
        }
    }

    @Test func swap_changesNothingWhenTheFirstMoveFails() async throws {
        try await withUpdateTree { tree in
            let setup = try makeSetup(tree)
            let installer = UpdateInstaller(
                files: FlakyFileOperations(failingMoves: [1]), allowedParents: [setup.applications])

            let error = try #require(throws: UpdateError.self) {
                try installer.swap(running: setup.running, new: setup.new)
            }
            #expect(error == .swapFailed(CocoaError(.fileWriteNoPermission).localizedDescription, restoredOldApp: true))
            #expect(FixtureApp.build(of: setup.running) == 1000)
            #expect(names(in: setup.applications) == ["TruongCleaner.app"])
            #expect(FixtureApp.build(of: setup.new) == 2000)
        }
    }

    @Test func swap_saysSoWhenTheOldAppCannotBePutBack() async throws {
        try await withUpdateTree { tree in
            let setup = try makeSetup(tree)
            // Moves 2 (new into place) and 3 (old back) both fail.
            let installer = UpdateInstaller(
                files: FlakyFileOperations(failingMoves: [2, 3]), allowedParents: [setup.applications])

            let error = try #require(throws: UpdateError.self) {
                try installer.swap(running: setup.running, new: setup.new)
            }
            guard case .swapFailed(_, let restored) = error else {
                Issue.record("Expected swapFailed, got \(error)")
                return
            }
            #expect(!restored)
            // The old app is still on disk, under its aside name.
            let leftovers = names(in: setup.applications)
            #expect(leftovers.count == 1)
            #expect(leftovers.allSatisfy(UpdateCleanup.isOldBundleName))
        }
    }

    // MARK: Where the app may live

    @Test func blocker_acceptsAnAppInAnAllowedFolder() async throws {
        try await withUpdateTree { tree in
            let setup = try makeSetup(tree)
            #expect(UpdateInstaller(allowedParents: [setup.applications]).blocker(for: setup.running) == nil)
        }
    }

    @Test func swap_refusesAnAppOutsideTheApplicationsFolders() async throws {
        try await withUpdateTree { tree in
            let setup = try makeSetup(tree)
            let elsewhere = try FixtureApp.make(in: tree, at: "Downloads/TruongCleaner.app")
            let installer = UpdateInstaller(allowedParents: [setup.applications])

            #expect(installer.blocker(for: elsewhere) == .installLocationNotSupported)
            #expect(throws: UpdateError.installLocationNotSupported) {
                try installer.swap(running: elsewhere, new: setup.new)
            }
            #expect(FixtureApp.build(of: elsewhere) == 2000)
            #expect(FixtureApp.build(of: setup.new) == 2000)
        }
    }

    @Test func swap_refusesAnAppInASubfolderOfApplications() async throws {
        try await withUpdateTree { tree in
            let setup = try makeSetup(tree)
            let nested = try FixtureApp.make(in: tree, at: "Applications/Utilities/TruongCleaner.app")
            #expect(UpdateInstaller(allowedParents: [setup.applications]).blocker(for: nested) == .installLocationNotSupported)
        }
    }

    @Test func swap_refusesAFolderTheUserCannotWriteTo() async throws {
        try await withUpdateTree { tree in
            let setup = try makeSetup(tree)
            try tree.setPermissions("Applications", mode: 0o555)
            let installer = UpdateInstaller(allowedParents: [setup.applications])

            #expect(installer.blocker(for: setup.running) == .notWritable)
            #expect(throws: UpdateError.notWritable) {
                try installer.swap(running: setup.running, new: setup.new)
            }
            #expect(FixtureApp.build(of: setup.running) == 1000)
        }
    }

    @Test func swap_refusesARunningPathThatIsASymlink() async throws {
        try await withUpdateTree { tree in
            try tree.addDirectory("Applications")
            let real = try FixtureApp.make(in: tree, at: "elsewhere/TruongCleaner.app")
            let link = try tree.addSymlink("Applications/TruongCleaner.app", destination: real)
            let new = try FixtureApp.make(in: tree, at: "staging/TruongCleaner.app")
            let installer = UpdateInstaller(allowedParents: [tree.url(for: "Applications")])

            #expect(throws: UpdateError.installLocationNotSupported) {
                try installer.swap(running: link, new: new)
            }
            #expect(FixtureApp.build(of: real) == 2000)
        }
    }

    @Test func standardParents_areApplicationsAndUserApplications() {
        let paths = UpdateInstaller.standardParents().map(UpdateWorkspace.unixPath)
        #expect(paths.first == "/Applications")
        #expect(paths.last == UpdateWorkspace.unixPath(FileManager.default.homeDirectoryForCurrentUser) + "/Applications")
        #expect(paths.count == 2)
    }
}
