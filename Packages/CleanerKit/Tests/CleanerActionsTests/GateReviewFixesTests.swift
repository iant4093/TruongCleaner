import CleanerCore
import CleanerTestSupport
import Darwin
import Foundation
import Synchronization
import Testing

@testable import CleanerActions
@testable import CleanerScanner

/// Pre-v1.0 safety review, findings 1, 2, 6, 7 and 10: the gate's rule-specific checks and its check order.
/// Fixture trees only.
struct GateReviewFixesTests {
    // MARK: Finding 1: mail.downloads

    private static func mailSetup(_ h: GateHarness) throws -> (root: URL, rule: Rule, context: GateContext) {
        let root = try h.tree.addDirectory("home/Library/Mail Downloads")
        return (root, h.rule(id: "mail.downloads"), h.context(roots: [root]))
    }

    @Test func mail_aFileChangedAfterItsDownloadKeepsTheWholeItem() async throws {
        try await withHarness { h in
            let (root, rule, context) = try Self.mailSetup(h)
            try h.tree.addFile("home/Library/Mail Downloads/ABC/deep/report.docx", size: 10)
            try h.tree.setModified("home/Library/Mail Downloads/ABC/deep/report.docx", to: Date().addingTimeInterval(3_600))
            let item = h.tree.url(for: "home/Library/Mail Downloads/ABC")
            let verdict = try await h.verdict(for: item, scanRoot: root, rule: rule, context: context)
            #expect(verdict == .deny(.editedAfterDownload))
        }
    }

    @Test func mail_aFileThatWasOnlyDownloadedIsAllowed() async throws {
        try await withHarness { h in
            let (root, rule, context) = try Self.mailSetup(h)
            try h.tree.addFile("home/Library/Mail Downloads/ABC/report.docx", size: 10, modified: h.ago(days: 60))
            try h.tree.addFile("home/Library/Mail Downloads/ABC/sheet.xlsx", size: 10, modified: h.ago(days: 90))
            let item = h.tree.url(for: "home/Library/Mail Downloads/ABC")
            #expect(try await h.verdict(for: item, scanRoot: root, rule: rule, context: context).isAllowed)
        }
    }

    @Test func mail_aSingleFileItemIsJudgedToo() async throws {
        try await withHarness { h in
            let (root, rule, context) = try Self.mailSetup(h)
            let edited = try h.tree.addFile("home/Library/Mail Downloads/edited.pdf", size: 10)
            try h.tree.setModified("home/Library/Mail Downloads/edited.pdf", to: Date().addingTimeInterval(3_600))
            let plain = try h.tree.addFile("home/Library/Mail Downloads/plain.pdf", size: 10, modified: h.ago(days: 40))
            #expect(try await h.verdict(for: edited, scanRoot: root, rule: rule, context: context) == .deny(.editedAfterDownload))
            #expect(try await h.verdict(for: plain, scanRoot: root, rule: rule, context: context).isAllowed)
        }
    }

    @Test func mail_aFolderThatCannotBeReadIsKept() async throws {
        try await withHarness { h in
            let (root, rule, context) = try Self.mailSetup(h)
            try h.tree.addFile("home/Library/Mail Downloads/ABC/sub/a.bin", size: 10, modified: h.ago(days: 60))
            let item = h.tree.url(for: "home/Library/Mail Downloads/ABC")
            let finding = try await h.scanned(item, scanRoot: root)
            try h.tree.setPermissions("home/Library/Mail Downloads/ABC/sub", mode: 0)
            let verdict = await SafetyGate().authorize(finding, rule: rule, context: context)
            guard case .deny(.probeFailed) = verdict else {
                Issue.record("Expected probeFailed, got \(verdict)")
                return
            }
        }
    }

    @Test func mail_otherRulesAreNotAskedForTheEditCheck() async throws {
        try await withHarness { h in
            let root = try h.tree.addDirectory("home/Library/Mail Downloads")
            let item = try h.tree.addFile("home/Library/Mail Downloads/edited.pdf", size: 10)
            try h.tree.setModified("home/Library/Mail Downloads/edited.pdf", to: Date().addingTimeInterval(3_600))
            let verdict = try await h.verdict(for: item, scanRoot: root, context: h.context(roots: [root]))
            #expect(verdict.isAllowed)
        }
    }

    // MARK: Finding 2: identity is the last check, and the verdict carries the verified URL

    @Test func identity_aSwapDuringTheSlowChecksIsCaught() async throws {
        try await withHarness { h in
            let folder = try h.tree.addDirectory("home/Library/Caches/victim")
            let aside = h.caches.appending(path: "victim-old", directoryHint: .isDirectory)
            let rule = h.rule(guards: Guards(owners: [.bundleID("com.example.Tool")]))
            // The owner query is a slow step after the old identity check. Swap the folder during it.
            let swap = ActingApps {
                try? FileManager.default.moveItem(at: folder, to: aside)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            let verdict = try await h.verdict(for: folder, rule: rule, context: h.context(apps: swap))
            #expect(verdict == .deny(.changedSinceScan))
        }
    }

    @Test func identity_aSwapDuringTheOpenFilesCheckIsCaught() async throws {
        try await withHarness { h in
            let file = try h.tree.addFile("home/Library/Caches/a.bin", size: 10)
            let aside = h.caches.appending(path: "a-old.bin")
            struct SwappingFiles: OpenFilesProvider {
                var swap: @Sendable () -> Void
                func hasOpenFiles(under url: URL) async -> Bool? {
                    swap()
                    return false
                }
            }
            let files = SwappingFiles {
                try? FileManager.default.moveItem(at: file, to: aside)
                _ = FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: Data(count: 10))
            }
            let verdict = try await h.verdict(for: file, context: h.context(files: files))
            #expect(verdict == .deny(.changedSinceScan))
        }
    }

    @Test func verdict_allowCarriesTheRealParentAndTheName() async throws {
        try await withHarness { h in
            let file = try h.tree.addFile("home/Library/Caches/a.txt", size: 10)
            let expected = try GateSystem.realPath(of: h.caches).appending(path: "a.txt")
            let verdict = try await h.verdict(for: file)
            #expect(verdict.verifiedURL?.path(percentEncoded: false) == expected.path(percentEncoded: false))
        }
    }

    @Test func verdict_theVerifiedURLIsTheRealPathEvenWhenTheRootIsReachedThroughALink() async throws {
        try await withHarness { h in
            let file = try h.tree.addFile("home/Library/Caches/a.txt", size: 10)
            let alias = try h.tree.addSymlink("home/alias", destination: h.caches)
            let given = alias.appending(path: "a.txt")
            let verdict = try await h.verdict(
                for: file, scanRoot: h.caches, given: given, context: h.context(roots: [alias]))
            let expected = try GateSystem.realPath(of: h.caches).appending(path: "a.txt")
            #expect(verdict.verifiedURL?.path(percentEncoded: false) == expected.path(percentEncoded: false))
            #expect(verdict.verifiedURL != given)
        }
    }

    // MARK: Finding 6: installers.macOS

    private static let installerID = "com.apple.InstallAssistant.macOSTest"

    private static func installerSetup(
        _ h: GateHarness, bundleID: String? = installerID
    ) throws -> (root: URL, app: URL) {
        let root = try h.tree.addDirectory("home/Installers")
        let app = try h.tree.addDirectory("home/Installers/Install macOS Test.app/Contents")
            .deletingLastPathComponent()
        if let bundleID {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0)
            try data.write(to: app.appending(path: "Contents/Info.plist"))
        }
        return (root, app)
    }

    private func installerVerdict(
        _ h: GateHarness, root: URL, app: URL, signature: Bool? = true, apps: any RunningAppsProvider = FakeApps()
    ) async throws -> Verdict {
        let context = h.context(
            roots: [root], apps: apps, allowWholeBundle: true, appSignature: FakeSignature(answer: signature))
        return try await h.verdict(
            for: app, scanRoot: root, rule: h.rule(id: Rule.wholeBundleRuleID), context: context)
    }

    @Test func installer_anAppleSignedInstallerThatIsNotRunningIsAllowed() async throws {
        try await withHarness { h in
            let (root, app) = try Self.installerSetup(h)
            #expect(try await installerVerdict(h, root: root, app: app).isAllowed)
        }
    }

    @Test func installer_anAppThatAppleDidNotSignIsKept() async throws {
        try await withHarness { h in
            let (root, app) = try Self.installerSetup(h)
            #expect(try await installerVerdict(h, root: root, app: app, signature: false) == .deny(.notAppleInstaller))
        }
    }

    @Test func installer_aSignatureThatCannotBeReadIsKept() async throws {
        try await withHarness { h in
            let (root, app) = try Self.installerSetup(h)
            let verdict = try await installerVerdict(h, root: root, app: app, signature: nil)
            guard case .deny(.probeFailed) = verdict else {
                Issue.record("Expected probeFailed, got \(verdict)")
                return
            }
        }
    }

    @Test(arguments: ["com.example.Installer", "com.apple.dt.Xcode", "com.apple.InstallAssistant", "com.apple.installassistant.x"])
    func installer_aBundleIDThatIsNotAnInstallAssistantIsKept(bundleID: String) async throws {
        try await withHarness { h in
            let (root, app) = try Self.installerSetup(h, bundleID: bundleID)
            #expect(try await installerVerdict(h, root: root, app: app) == .deny(.notAppleInstaller))
        }
    }

    @Test func installer_anAppWithoutABundleIDIsKept() async throws {
        try await withHarness { h in
            let (root, app) = try Self.installerSetup(h, bundleID: nil)
            #expect(try await installerVerdict(h, root: root, app: app) == .deny(.notAppleInstaller))
        }
    }

    @Test func installer_aRunningInstallerIsKept() async throws {
        try await withHarness { h in
            let (root, app) = try Self.installerSetup(h)
            let running = FakeApps(answers: [.bundleID(Self.installerID): .running])
            #expect(try await installerVerdict(h, root: root, app: app, apps: running) == .deny(.ownerOpen(Self.installerID)))
            let unknown = FakeApps(answers: [.bundleID(Self.installerID): .unknown])
            #expect(try await installerVerdict(h, root: root, app: app, apps: unknown) == .deny(.ownerUnknown))
        }
    }

    @Test func installer_theRealCheckerDoesNotTrustAnUnsignedApp() async throws {
        try await withHarness { h in
            let (_, app) = try Self.installerSetup(h)
            #expect(SecurityAppSignatureChecker().isAppleSigned(app) != true)
        }
    }

    @Test func installer_theRealCheckerRecognisesAnAppleApp() throws {
        let calculator = URL(filePath: "/System/Applications/Calculator.app", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: calculator.path(percentEncoded: false)) else { return }
        #expect(SecurityAppSignatureChecker().isAppleSigned(calculator) == true)
    }

    // MARK: Finding 7: dev.projectArtifacts and git

    private static func projectSetup(
        _ h: GateHarness, git: GitFixture = .directory
    ) throws -> (root: URL, item: URL) {
        let root = try h.tree.addDirectory("home/Projects")
        let item = try h.tree.addFile("home/Projects/app/Pods/Pod.swift", size: 10)
            .deletingLastPathComponent()
        switch git {
        case .none: break
        case .directory: try h.tree.addDirectory("home/Projects/app/.git")
        case .file: try h.tree.addFile("home/Projects/app/.git", size: 10)
        }
        return (root, item)
    }

    private enum GitFixture {
        case none, directory, file
    }

    private func projectVerdict(_ h: GateHarness, root: URL, item: URL, git: any GitTrackingProbe) async throws -> Verdict {
        try await h.verdict(
            for: item, scanRoot: root, rule: h.rule(id: "dev.projectArtifacts"),
            context: h.context(roots: [root], git: git))
    }

    @Test func git_aTrackedBuildFolderIsKept() async throws {
        try await withHarness { h in
            let (root, item) = try Self.projectSetup(h)
            let git = FakeGit(answer: .tracked)
            #expect(try await projectVerdict(h, root: root, item: item, git: git) == .deny(.trackedByGit))
            let asked = try #require(git.questions.first)
            #expect(asked.path == "Pods")
            #expect(asked.repository.lastPathComponent == "app")
        }
    }

    @Test func git_anUntrackedBuildFolderIsAllowed() async throws {
        try await withHarness { h in
            let (root, item) = try Self.projectSetup(h)
            let git = FakeGit(answer: .untracked)
            #expect(try await projectVerdict(h, root: root, item: item, git: git).isAllowed)
            #expect(git.questions.count == 1)
        }
    }

    @Test(arguments: [
        GitTracking.unknown("git failed"), .unknown("git timed out"), .unknown("git not available"),
    ])
    func git_anErrorOrATimeoutKeepsTheFolder(answer: GitTracking) async throws {
        try await withHarness { h in
            let (root, item) = try Self.projectSetup(h)
            let verdict = try await projectVerdict(h, root: root, item: item, git: FakeGit(answer: answer))
            guard case .deny(.probeFailed) = verdict else {
                Issue.record("Expected probeFailed, got \(verdict)")
                return
            }
        }
    }

    @Test func git_aProjectWithoutARepositoryIsNeverAsked() async throws {
        try await withHarness { h in
            let (root, item) = try Self.projectSetup(h, git: .none)
            let git = FakeGit(answer: .tracked)
            #expect(try await projectVerdict(h, root: root, item: item, git: git).isAllowed)
            #expect(git.questions.isEmpty)
        }
    }

    @Test func git_aGitFileCountsAsARepository() async throws {
        try await withHarness { h in
            let (root, item) = try Self.projectSetup(h, git: .file)
            let git = FakeGit(answer: .tracked)
            #expect(try await projectVerdict(h, root: root, item: item, git: git) == .deny(.trackedByGit))
        }
    }

    @Test func git_theNearestRepositoryAboveAnArtifactInASubfolderIsUsed() async throws {
        try await withHarness { h in
            try h.tree.addDirectory("home/Projects/mono/.git")
            let item = try h.tree.addFile("home/Projects/mono/packages/web/node_modules/x.js", size: 10)
                .deletingLastPathComponent()
            let root = h.tree.url(for: "home/Projects")
            let git = FakeGit(answer: .tracked)
            #expect(try await projectVerdict(h, root: root, item: item, git: git) == .deny(.trackedByGit))
            #expect(git.questions.first?.path == "packages/web/node_modules")
        }
    }

    @Test func git_aRepositoryAboveTheProjectFolderIsFound() async throws {
        try await withHarness { h in
            try h.tree.addDirectory("home/Projects/.git")
            let root = try h.tree.addDirectory("home/Projects/sub")
            let item = try h.tree.addFile("home/Projects/sub/app/build/x.o", size: 10).deletingLastPathComponent()
            let git = FakeGit(answer: .tracked)
            #expect(try await projectVerdict(h, root: root, item: item, git: git) == .deny(.trackedByGit))
            #expect(git.questions.first?.path == "sub/app/build")
        }
    }

    @Test func git_otherRulesAreNotAskedAboutGit() async throws {
        try await withHarness { h in
            let (root, item) = try Self.projectSetup(h)
            let git = FakeGit(answer: .tracked)
            let verdict = try await h.verdict(
                for: item, scanRoot: root, context: h.context(roots: [root], git: git))
            #expect(verdict.isAllowed)
            #expect(git.questions.isEmpty)
        }
    }

    @Test func git_theRealProbeSeesTrackedAndUntrackedFolders() async throws {
        try await withHarness { h in
            let app = try h.tree.addDirectory("home/Projects/app")
            try h.tree.addFile("home/Projects/app/Pods/Pod.swift", size: 10)
            try h.tree.addFile("home/Projects/app/build/out.o", size: 10)
            try h.tree.addFile("home/Projects/app/*/star.txt", size: 10)
            #expect(try Self.runGit(["init", "-q"], in: app) == 0)
            #expect(try Self.runGit(["add", "--", "Pods/Pod.swift"], in: app) == 0)

            let probe = GitCommandProbe()
            #expect(await probe.tracking(of: "Pods", inRepository: app) == .tracked)
            #expect(await probe.tracking(of: "build", inRepository: app) == .untracked)
            #expect(await probe.tracking(of: "does-not-exist", inRepository: app) == .untracked)
            // `*` is a folder name here, not a pattern for every file.
            #expect(await probe.tracking(of: "*", inRepository: app) == .untracked)
        }
    }

    @Test func git_theRealProbeSaysUnknownWhenGitCannotAnswer() async throws {
        try await withHarness { h in
            // A folder that does not exist: git exits with a fatal error, which is neither tracked nor untracked.
            let folder = h.tree.root.appending(path: "no-such-folder", directoryHint: .isDirectory)
            let answer = await GitCommandProbe().tracking(of: "build", inRepository: folder)
            guard case .unknown = answer else {
                Issue.record("Expected unknown, got \(answer)")
                return
            }
            guard case .unknown = await GitCommandProbe().tracking(of: "", inRepository: folder) else {
                Issue.record("An empty path must be unknown")
                return
            }
        }
    }

    @Test func git_theArgumentListIsFixedAroundTwoValidatedPaths() {
        let repository = URL(filePath: "/tmp/repo", directoryHint: .notDirectory)
        #expect(
            GitCommandProbe.arguments(for: "build", repository: repository) == [
                "--literal-pathspecs", "-c", "core.fsmonitor=false", "-C", "/tmp/repo",
                "ls-files", "-z", "--error-unmatch", "--", "build",
            ])
        #expect(GitCommandProbe.executable == "/usr/bin/git")
    }

    /// Runs git inside a fixture folder and returns its exit status. Output is discarded.
    private static func runGit(_ arguments: [String], in folder: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", folder.path(percentEncoded: false)] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: Finding 10: keep-newest at the door

    @Test func keepNewest_filesAndDotNamesDoNotCountAsNewerSiblings() async throws {
        try await withHarness { h in
            let names = ["d1", "d2"]
            for name in names { try h.tree.addDirectory("home/Library/Caches/\(name)") }
            try h.tree.addDirectory("home/Library/Caches/.hidden")
            try h.tree.addFile("home/Library/Caches/.DS_Store", size: 1)
            try h.tree.addFile("home/Library/Caches/newer.txt", size: 1)
            try h.tree.setModified("home/Library/Caches/d1", to: h.ago(days: 30))
            try h.tree.setModified("home/Library/Caches/d2", to: h.ago(days: 20))
            try h.tree.setModified("home/Library/Caches/.hidden", to: h.ago(days: 1))
            try h.tree.setModified("home/Library/Caches/.DS_Store", to: h.ago(days: 1))
            try h.tree.setModified("home/Library/Caches/newer.txt", to: h.ago(days: 1))
            let rule = h.rule(guards: Guards(keepNewest: 1))
            // d2 is the newest folder. The newer file and dot-names are not siblings of its shape.
            #expect(try await h.verdict(for: h.tree.url(for: "home/Library/Caches/d2"), rule: rule) == .deny(.keepNewest))
            #expect(try await h.verdict(for: h.tree.url(for: "home/Library/Caches/d1"), rule: rule).isAllowed)
        }
    }

    @Test func keepNewest_aSiblingWithAnUnknownDateCountsAsNewer() {
        let name = Array("item".utf8)
        let own = Date(timeIntervalSince1970: 1_000)
        let siblings = [
            DirectoryChild(name: Array("older".utf8), modified: Date(timeIntervalSince1970: 500), isDirectory: true),
            DirectoryChild(name: Array("undated".utf8), modified: nil, isDirectory: true),
            DirectoryChild(name: Array("undated-kind".utf8), modified: nil, isDirectory: nil),
            DirectoryChild(name: Array("undated-file".utf8), modified: nil, isDirectory: false),
            DirectoryChild(name: Array(".dot".utf8), modified: nil, isDirectory: true),
            DirectoryChild(name: name, modified: own, isDirectory: true),
        ]
        // Counted: `undated` and `undated-kind`. Not counted: older, a file, a dot-name, the item.
        #expect(SafetyGate.countNewer(siblings, than: name, ownDate: own, ownIsDirectory: true) == 2)
    }

    // MARK: Brief 9.4: the age walk uses the shared walker budget

    /// Set when a gate run ends.
    private final class DoneFlag: Sendable {
        private let state = Mutex(false)
        func set() { state.withLock { $0 = true } }
        var isSet: Bool { state.withLock { $0 } }
    }

    private static let weekRule = Guards(minAge: .seconds(7 * 86_400))

    /// Runs the gate in a task that sees `budget` as the shared budget, and says when it finished.
    private static func authorizeUnder(
        _ budget: WorkerBudget, finding: Finding, rule: Rule, context: GateContext, finished: DoneFlag
    ) -> Task<Verdict, Never> {
        WorkerBudget.$current.withValue(budget) {
            Task {
                let verdict = await SafetyGate().authorize(finding, rule: rule, context: context)
                finished.set()
                return verdict
            }
        }
    }

    @Test func ageWalk_waitsForALaneOfTheSharedBudget() async throws {
        try await withHarness { h in
            let folder = try h.tree.addFile("home/Library/Caches/old/a.bin", size: 10, modified: h.ago(days: 90))
                .deletingLastPathComponent()
            try h.tree.setModified("home/Library/Caches/old", to: h.ago(days: 90))
            let finding = try await h.scanned(folder)
            let rule = h.rule(guards: Self.weekRule)
            let context = h.context()

            // The test holds the only lane. A walk outside the budget would finish at once.
            let budget = WorkerBudget(total: 1)
            #expect(budget.tryStartLane())
            let finished = DoneFlag()
            let task = Self.authorizeUnder(budget, finding: finding, rule: rule, context: context, finished: finished)
            try await Task.sleep(for: .milliseconds(200))
            #expect(!finished.isSet)
            #expect(budget.used == 1)

            budget.endLane()
            let verdict = await task.value
            #expect(verdict.isAllowed)
            #expect(budget.used == 0)
        }
    }

    @Test func ageWalk_cancelledWhileWaitingForALaneIsDeniedNeverAllowed() async throws {
        try await withHarness { h in
            let folder = try h.tree.addFile("home/Library/Caches/old/a.bin", size: 10, modified: h.ago(days: 90))
                .deletingLastPathComponent()
            try h.tree.setModified("home/Library/Caches/old", to: h.ago(days: 90))
            let finding = try await h.scanned(folder)
            let rule = h.rule(guards: Self.weekRule)

            let budget = WorkerBudget(total: 1)
            #expect(budget.tryStartLane())
            let finished = DoneFlag()
            let task = Self.authorizeUnder(
                budget, finding: finding, rule: rule, context: h.context(), finished: finished)
            try await Task.sleep(for: .milliseconds(100))
            task.cancel()
            #expect(await task.value == .deny(.unknownAge))
            // The cancelled gate took no lane.
            #expect(budget.used == 1)
            budget.endLane()
        }
    }

    @Test func ageWalk_aFreeLaneIsGivenBackAfterTheCheck() async throws {
        try await withHarness { h in
            let folder = try h.tree.addFile("home/Library/Caches/fresh/a.bin", size: 10)
                .deletingLastPathComponent()
            let finding = try await h.scanned(folder)
            let budget = WorkerBudget(total: 2)
            let finished = DoneFlag()
            let task = Self.authorizeUnder(
                budget, finding: finding, rule: h.rule(guards: Self.weekRule), context: h.context(), finished: finished)
            #expect(await task.value == .deny(.tooNew))
            #expect(budget.used == 0)
        }
    }
}
