import CleanerCore
import CleanerScanner
import CleanerTestSupport
import Darwin
import Foundation
import Synchronization
import Testing

@testable import CleanerActions

/// A fixture home for gate tests: `<fixture>/home/Library/Caches` is the default rule root.
/// Nothing here touches the real home folder.
struct GateHarness {
    let tree: FixtureTree
    let home: URL
    let caches: URL
    let environment: Environment

    init() throws {
        tree = try FixtureTree()
        home = try tree.addDirectory("home")
        caches = try tree.addDirectory("home/Library/Caches")
        environment = Environment(home: home, now: Date())
    }

    /// A date `days` days before the harness clock.
    func ago(days: Double) -> Date { environment.now.addingTimeInterval(-days * 86_400) }

    func policy(exclusions: [URL] = []) -> PathPolicy {
        PathPolicy(environment: environment, userExclusions: exclusions)
    }

    /// A rule. Only the fields the gate reads matter; `roots` is a placeholder because the
    /// gate takes concrete roots from the context.
    func rule(
        tier: Tier = .safe,
        action: Action = .trash,
        guards: Guards = Guards()
    ) -> Rule {
        Rule(
            id: "test.rule",
            category: .caches,
            tier: tier,
            roots: [RootSpec(base: .home, components: ["Library", "Caches"])],
            match: .children,
            guards: guards,
            access: .user,
            action: action,
            title: "Test",
            explain: "Test rule"
        )
    }

    func context(
        roots: [URL]? = nil,
        exclusions: [URL] = [],
        apps: any RunningAppsProvider = FakeApps(),
        files: any OpenFilesProvider = FakeFiles(answer: false),
        allowWholeBundle: Bool = false
    ) -> GateContext {
        GateContext(
            environment: environment,
            policy: policy(exclusions: exclusions),
            expandedRoots: roots ?? [caches],
            runningApps: apps,
            openFiles: files,
            allowWholeBundle: allowWholeBundle
        )
    }

    /// A finding for `item` with the identity a real scan of `scanRoot` recorded (via `BulkWalker`).
    /// `given` overrides the URL the finding carries, to test paths that differ from the real one.
    func scanned(_ item: URL, scanRoot: URL? = nil, given: URL? = nil) async throws -> Finding {
        let root = scanRoot ?? caches
        let result = try await BulkWalker.walk(root, options: WalkOptions(maxWorkers: 1, totalsDepth: 16))
        let wanted = Self.trimmed(item.path(percentEncoded: false))
        let node = try #require(result.nodes.first { Self.trimmed($0.url.path(percentEncoded: false)) == wanted })
        return Finding(
            ruleID: "test.rule",
            url: given ?? item,
            fsid: node.id.fsid,
            fileID: node.id.fileID,
            allocatedBytes: node.allocatedBytes,
            privateBytes: node.privateBytes,
            newestModification: node.newestModification,
            isDirectory: node.kind == .directory,
            isSymlink: node.kind == .symlink,
            flags: node.flags,
            itemCount: node.fileCount
        )
    }

    /// A path without a trailing slash, so folder URLs compare equal.
    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Runs the gate for a scanned item.
    func verdict(
        for item: URL,
        scanRoot: URL? = nil,
        given: URL? = nil,
        rule: Rule? = nil,
        context: GateContext? = nil
    ) async throws -> Verdict {
        let finding = try await scanned(item, scanRoot: scanRoot, given: given)
        return await SafetyGate().authorize(finding, rule: rule ?? self.rule(), context: context ?? self.context())
    }
}

/// Runs `body` with a fresh harness and removes the fixture afterwards.
func withHarness(_ body: (GateHarness) async throws -> Void) async throws {
    let harness = try GateHarness()
    defer { harness.tree.remove() }
    try await body(harness)
}

/// Returns a fixed answer per owner.
struct FakeApps: RunningAppsProvider {
    var answers: [OwnerSpec: OwnerState] = [:]
    var fallback: OwnerState = .notRunning

    func state(of owner: OwnerSpec, for item: URL) async -> OwnerState {
        answers[owner] ?? fallback
    }
}

/// Remembers which owners it was asked about.
final class RecordingApps: RunningAppsProvider, Sendable {
    private let asked = Mutex<[OwnerSpec]>([])
    private let answer: OwnerState

    init(answer: OwnerState = .notRunning) { self.answer = answer }

    var owners: [OwnerSpec] { asked.withLock { $0 } }

    func state(of owner: OwnerSpec, for item: URL) async -> OwnerState {
        asked.withLock { $0.append(owner) }
        return answer
    }
}

/// Returns a fixed open-files answer.
struct FakeFiles: OpenFilesProvider {
    var answer: Bool?

    func hasOpenFiles(under url: URL) async -> Bool? { answer }
}

/// Sets BSD flags, bypassing `FixtureTree.setFlags`, which refuses immutable flags.
/// Always reset them before the fixture is removed.
func setFlags(_ url: URL, _ flags: Int32) {
    _ = chflags(url.path(percentEncoded: false), UInt32(flags))
}
