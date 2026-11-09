import CleanerCore
import CleanerScanner
import CleanerTestSupport
import Darwin
import Foundation
import Testing

@testable import CleanerActions

/// An uninstall through the real finder, `SafetyGate` and `Cleaner`, on a fixture machine. The Trash is a
/// folder inside the fixture; nothing touches the real Trash, Library or Applications.
private struct Machine {
    let tree: FixtureTree
    let home: URL
    let applications: URL
    let trash: URL
    let history: HistoryStore
    let executor: FakeTrashExecutor
    let environment: CleanerCore.Environment

    init() throws {
        tree = try FixtureTree()
        home = try tree.addDirectory("home")
        try tree.addDirectory("home/Library")
        applications = try tree.addDirectory("Applications")
        try tree.addDirectory("Library")
        trash = try tree.addDirectory(".Trash")
        history = HistoryStore(fileURL: tree.url(for: "state/history.jsonl"))
        executor = FakeTrashExecutor(trash: trash)
        environment = CleanerCore.Environment(home: home, now: Date())
    }

    func remove() { tree.remove() }

    var uninstallContext: UninstallContext {
        UninstallContext(
            home: home, systemLibrary: tree.url(for: "Library"),
            applicationFolders: [applications, tree.url(for: "home/Applications")],
            ownBundleID: "com.iant4093.TruongCleaner", currentUserID: UInt32(getuid()))
    }

    /// Adds an unsigned app with a plist and an executable.
    @discardableResult
    func addApp(_ file: String = "Foo", bundleID: String = "com.example.Foo", name: String = "Foo Tool") throws -> URL {
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundleExecutable": "exec",
        ]
        let info = try tree.addFile("Applications/\(file).app/Contents/Info.plist", size: 0)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: info)
        try tree.addFile("Applications/\(file).app/Contents/MacOS/exec", size: 4_096)
        return tree.url(for: "Applications/\(file).app")
    }

    /// Runs the real finder for `bundleID`.
    func report(_ bundleID: String = "com.example.Foo") async throws -> UninstallReport {
        let inventory = await AppInventory.scan(folders: uninstallContext.applicationFolders)
        let app = try #require(inventory.apps.first { $0.bundleID == bundleID })
        return try await LeftoverFinder.find(
            for: app, inventory: inventory, isRunning: false, context: uninstallContext
        ).get()
    }

    /// The plan for the bundle and the leftovers the user would leave checked (Safe ones).
    func plan(_ report: UninstallReport, including: (Leftover) -> Bool = { $0.tier == .safe }) -> CleanPlan {
        let rule = report.setup.rule
        let roots = report.setup.expandedRoots
        var items = [PlannedItem(finding: report.bundle, rule: rule, expandedRoots: roots)]
        items += report.leftovers.filter(including).map { PlannedItem(finding: $0.finding, rule: rule, expandedRoots: roots) }
        return CleanPlan(items: items)
    }

    func cleaner(
        apps: any RunningAppsProvider = FakeApps(),
        files: any OpenFilesProvider = FakeFiles(answer: false)
    ) -> Cleaner {
        let environment = environment
        let policy = PathPolicy(environment: environment, userExclusions: [])
        return Cleaner(
            gate: SafetyGate(),
            executor: executor,
            history: history,
            context: { item in
                GateContext(
                    environment: environment, policy: policy, expandedRoots: item.expandedRoots,
                    runningApps: apps, openFiles: files,
                    allowWholeBundle: item.rule.allowsWholeBundle, rootOwners: [:])
            },
            openFilesSource: { files })
    }

    var undo: UndoService {
        UndoService(trash: TrashLocations(home: home, additionalFolders: [trash]))
    }
}

private func withMachine(_ body: (Machine) async throws -> Void) async throws {
    let machine = try Machine()
    defer { machine.remove() }
    try await body(machine)
}

struct UninstallCleanTests {
    private func addLeftovers(_ machine: Machine) throws {
        let tree = machine.tree
        try tree.addFile("home/Library/Caches/com.example.Foo/blob", size: 1_000)
        try tree.addFile("home/Library/Preferences/com.example.Foo.plist", size: 100)
        try tree.addFile("home/Library/Application Support/Foo Tool/db", size: 1_000)
        try tree.addFile("home/Library/Caches/com.other.Bar/blob", size: 1_000)
        try tree.addFile("home/Documents/Foo Tool/report.txt", size: 100)
    }

    // MARK: The happy path

    @Test func theAppAndItsCheckedLeftoversGoToTheTrashAsOneRecordedClean() async throws {
        try await withMachine { machine in
            let app = try machine.addApp()
            try addLeftovers(machine)
            let report = try await machine.report()
            let result = await machine.cleaner().run(machine.plan(report), progress: { _ in })

            // Bundle, the Caches folder and the plist are moved. The Review item (name only) is not in the plan.
            #expect(result.items.count == 3)
            for entry in result.items { #expect(entry.outcome.movedURL != nil, "\(entry.originalPath.lastPathComponent)") }
            #expect(!exists(app))
            #expect(!exists(machine.tree.url(for: "home/Library/Caches/com.example.Foo")))
            #expect(!exists(machine.tree.url(for: "home/Library/Preferences/com.example.Foo.plist")))
            #expect(exists(machine.tree.url(for: "home/Library/Application Support/Foo Tool")))

            // Other data is untouched.
            #expect(exists(machine.tree.url(for: "home/Library/Caches/com.other.Bar/blob")))
            #expect(exists(machine.tree.url(for: "home/Documents/Foo Tool/report.txt")))

            let cleans = try await machine.history.cleans()
            #expect(cleans.count == 1)
            #expect(cleans.first?.plannedCount == 3)
            #expect(cleans.first?.movedCount == 3)
            #expect(Set(result.items.map(\.ruleID)) == ["apps.uninstall"])
        }
    }

    @Test func putBackRestoresTheWholeApp() async throws {
        try await withMachine { machine in
            let app = try machine.addApp()
            try addLeftovers(machine)
            let report = try await machine.report()
            let result = await machine.cleaner().run(machine.plan(report), progress: { _ in })
            let bundleEntry = try #require(result.items.first { $0.originalPath.lastPathComponent == "Foo.app" })
            #expect(!exists(app))

            let put = await machine.undo.putBack(bundleEntry, cleanID: result.id, history: machine.history)
            guard case .restored = put else {
                Issue.record("Expected restored, got \(put)")
                return
            }
            #expect(exists(app))
            #expect(exists(app.appending(path: "Contents/MacOS/exec")))
        }
    }

    @Test func aReviewLeftoverTheUserCheckedIsMovedToo() async throws {
        try await withMachine { machine in
            try machine.addApp()
            try addLeftovers(machine)
            let report = try await machine.report()
            let result = await machine.cleaner().run(machine.plan(report, including: { _ in true }), progress: { _ in })
            #expect(result.items.count == 4)
            #expect(result.items.allSatisfy { $0.outcome.movedURL != nil })
            #expect(!exists(machine.tree.url(for: "home/Library/Application Support/Foo Tool")))
        }
    }

    // MARK: Safety rules for the uninstall rule

    @Test func incident_mole1854_whileTheAppRunsEveryItemIsSkipped() async throws {
        try await withMachine { machine in
            let app = try machine.addApp()
            try addLeftovers(machine)
            let report = try await machine.report()
            let apps = FakeApps(answers: [.bundleID("com.example.Foo"): .running])
            let result = await machine.cleaner(apps: apps).run(machine.plan(report), progress: { _ in })

            #expect(result.items.count == 3)
            for entry in result.items { #expect(entry.outcome == .skipped(.ownerOpen("com.example.Foo"))) }
            #expect(exists(app))
            #expect(machine.executor.callCount == 0)
        }
    }

    @Test func incident_mole1854_aRunStateThatCannotBeReadSkipsEveryItem() async throws {
        try await withMachine { machine in
            let app = try machine.addApp()
            try addLeftovers(machine)
            let report = try await machine.report()
            let apps = FakeApps(answers: [.bundleID("com.example.Foo"): .unknown])
            let result = await machine.cleaner(apps: apps).run(machine.plan(report), progress: { _ in })
            #expect(result.items.allSatisfy { $0.outcome == .skipped(.ownerUnknown) })
            #expect(exists(app))
        }
    }

    @Test func aWholeAppMayBeRemovedOnlyByTheTwoWholeBundleRules() async throws {
        try await withMachine { machine in
            let app = try machine.addApp()
            let report = try await machine.report()
            // The same rule under another ID does not get the whole-bundle exception.
            let imposter = Rule(
                id: "apps.imposter", category: .apps, tier: .review, roots: report.setup.rule.roots,
                match: .children, guards: report.setup.rule.guards, access: .user, action: .trash,
                title: "x", explain: "x")
            let item = PlannedItem(finding: report.bundle, rule: imposter, expandedRoots: report.setup.expandedRoots)
            let result = await machine.cleaner().run(CleanPlan(items: [item]), progress: { _ in })
            #expect(result.items[0].outcome == .skipped(.insideBundle))
            #expect(exists(app))
        }
    }

    @Test func nothingInsideTheAppBundleIsEverRemovedAlone() async throws {
        try await withMachine { machine in
            let app = try machine.addApp()
            let report = try await machine.report()
            let inner = app.appending(path: "Contents/MacOS/exec")
            let identity = try GateSystem.identity(of: inner)
            let finding = Finding(
                ruleID: "apps.uninstall", url: inner, fsid: identity.fsid, fileID: identity.fileID,
                allocatedBytes: 4_096, privateBytes: 4_096, newestModification: nil, isDirectory: false,
                isSymlink: false, flags: 0, itemCount: 1)
            let item = PlannedItem(finding: finding, rule: report.setup.rule, expandedRoots: report.setup.expandedRoots)
            let result = await machine.cleaner().run(CleanPlan(items: [item]), progress: { _ in })
            #expect(result.items[0].outcome == .skipped(.insideBundle))
            #expect(exists(inner))
        }
    }

    @Test func theFoldersTheRuleLooksInAreNeverRemovedThemselves() async throws {
        try await withMachine { machine in
            try machine.addApp()
            try addLeftovers(machine)
            let report = try await machine.report()
            var items: [PlannedItem] = []
            for folder in [machine.applications, machine.tree.url(for: "home/Library/Caches"), machine.tree.url(for: "home/Library")] {
                let identity = try GateSystem.identity(of: folder)
                let finding = Finding(
                    ruleID: "apps.uninstall", url: folder, fsid: identity.fsid, fileID: identity.fileID,
                    allocatedBytes: 0, privateBytes: 0, newestModification: nil, isDirectory: true,
                    isSymlink: false, flags: 0, itemCount: 1)
                items.append(PlannedItem(finding: finding, rule: report.setup.rule, expandedRoots: report.setup.expandedRoots))
            }
            let result = await machine.cleaner().run(CleanPlan(items: items), progress: { _ in })
            #expect(result.items.allSatisfy { $0.outcome.skipReason != nil })
            #expect(exists(machine.applications))
            #expect(exists(machine.tree.url(for: "home/Library/Caches/com.other.Bar/blob")))
        }
    }

    @Test func theProtectedListStillWinsForAnUninstall() async throws {
        try await withMachine { machine in
            let app = try machine.addApp("1Password", bundleID: "com.example.vault", name: "Vault")
            let report = try await machine.report("com.example.vault")
            let result = await machine.cleaner().run(machine.plan(report), progress: { _ in })
            guard case .skipped(.protectedPath)? = result.items.first?.outcome else {
                Issue.record("Expected protectedPath, got \(String(describing: result.items.first?.outcome))")
                return
            }
            #expect(exists(app))
        }
    }

    @Test func anItemThatChangedSinceTheScanIsSkipped() async throws {
        try await withMachine { machine in
            try machine.addApp()
            try addLeftovers(machine)
            let report = try await machine.report()
            // Replace the plist after the scan: same name, different file.
            let plist = machine.tree.url(for: "home/Library/Preferences/com.example.Foo.plist")
            try FileManager.default.removeItem(at: plist)
            try machine.tree.addFile("home/Library/Preferences/com.example.Foo.plist", size: 200)

            let result = await machine.cleaner().run(machine.plan(report), progress: { _ in })
            let entry = try #require(result.items.first { $0.originalPath.lastPathComponent == "com.example.Foo.plist" })
            #expect(entry.outcome == .skipped(.changedSinceScan))
            #expect(exists(plist))
        }
    }

    @Test func anItemAProcessHasOpenIsSkipped() async throws {
        try await withMachine { machine in
            let app = try machine.addApp()
            let report = try await machine.report()
            let result = await machine.cleaner(files: FakeFiles(answer: true)).run(machine.plan(report), progress: { _ in })
            #expect(result.items[0].outcome == .skipped(.openFiles))
            #expect(exists(app))
        }
    }

    @Test func previewAndCleanAgree() async throws {
        try await withMachine { machine in
            try machine.addApp()
            try addLeftovers(machine)
            let report = try await machine.report()
            let plan = machine.plan(report)

            // The owner is running: preview denies, and the clean skips for exactly those reasons.
            let running = machine.cleaner(apps: FakeApps(answers: [.bundleID("com.example.Foo"): .running]))
            let denied = await running.preview(plan)
            let skipped = await running.run(plan, progress: { _ in })
            #expect(machine.executor.callCount == 0)
            for entry in skipped.items {
                guard case .deny(let reason)? = denied[entry.findingID] else {
                    Issue.record("Preview allowed an item the clean skipped")
                    continue
                }
                #expect(entry.outcome == .skipped(reason))
            }

            // The owner is closed: preview allows everything, changes nothing, and the clean moves it.
            let closed = machine.cleaner()
            let allowed = await closed.preview(plan)
            #expect(machine.executor.callCount == 0)
            #expect(plan.items.allSatisfy { if case .allow? = allowed[$0.finding.id] { true } else { false } })
            let moved = await closed.run(plan, progress: { _ in })
            #expect(moved.items.allSatisfy { $0.outcome.movedURL != nil })
        }
    }

    @Test func permanentDeleteIsNotPossibleWithoutTheExplicitConfirmation() async throws {
        try await withMachine { machine in
            let app = try machine.addApp()
            let report = try await machine.report()
            var plan = machine.plan(report)
            plan.mode = .permanent
            plan.permanentConfirmed = false
            let result = await machine.cleaner().run(plan, progress: { _ in })
            #expect(result.items.allSatisfy { $0.outcome.skipReason != nil })
            #expect(exists(app))
            #expect(machine.executor.deleted.isEmpty)
        }
    }
}
