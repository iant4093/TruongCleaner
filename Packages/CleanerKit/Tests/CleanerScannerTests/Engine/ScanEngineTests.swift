import CleanerCore
import CleanerTestSupport
import Foundation
import Synchronization
import Testing
@testable import CleanerScanner

/// Runs file-system setup that takes a while (thousands of files) on a dispatch thread of its own.
/// Left on the cooperative pool it holds one of the few threads (three on a small CI runner) while
/// the timing tests in the same run wait for a free one.
private func offPool(_ setup: @escaping @Sendable () throws -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        setupQueue.async {
            do {
                try setup()
                continuation.resume()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private let setupQueue = DispatchQueue(label: "TruongCleaner.TestSetup", qos: .userInitiated)

/// Engine tests. Every tree is a fixture under `build/test-fixtures/`; nothing reads the real home folder.
struct ScanEngineTests {
    private let week = Duration.seconds(7 * 86_400)

    // MARK: 1. Children

    @Test
    func childrenRuleOffersOneFindingPerChildWithWalkerSizes() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Caches/com.a.App/one.bin", pages: 2)
        try fixture.file("Library/Caches/com.b.App/deep/two.bin", pages: 3)
        try fixture.file("Library/Caches/com.b.App/three.bin", pages: 1)
        try fixture.file("Library/Caches/loose.bin", pages: 1)

        let rule = makeRule("test.caches", roots: [["Library", "Caches"]])
        let (events, report) = await fixture.scan([rule])
        let result = try #require(fixture.result("test.caches", in: report))

        #expect(result.findings.map(\.name) == ["com.a.App", "com.b.App", "loose.bin"])
        #expect(result.findings.map(\.allocatedBytes) == [fixture.bytes(2), fixture.bytes(4), fixture.bytes(1)])
        #expect(result.measuredBytes == fixture.bytes(7))
        #expect(result.measuredPrivateBytes == result.findings.reduce(0) { $0 + $1.privateBytes })
        #expect(result.partial == false)
        #expect(result.needsAccess.isEmpty)
        #expect(result.missingRoots.isEmpty)

        // Same numbers as a plain walk of the root.
        let walk = try await BulkWalker.walk(
            fixture.url("Library/Caches"), options: WalkOptions(maxWorkers: 2, totalsDepth: 1))
        for finding in result.findings {
            let node = try #require(walk.nodes.first { $0.url.path == finding.url.path })
            #expect(node.allocatedBytes == finding.allocatedBytes)
            #expect(node.privateBytes == finding.privateBytes)
            #expect(node.id.fileID == finding.fileID)
            #expect(node.id.fsid == finding.fsid)
        }
        let folder = try #require(result.findings.first { $0.name == "com.b.App" })
        #expect(folder.isDirectory && !folder.isSymlink)
        #expect(folder.itemCount == 2)

        // Events: started before finished, finished last.
        let tags = events.compactMap { event -> String? in
            switch event {
            case .ruleStarted(let id): "started \(id)"
            case .ruleFinished(let result): "finished \(result.ruleID)"
            case .finished: "report"
            case .progress: nil
            }
        }
        #expect(tags == ["started test.caches", "finished test.caches", "report"])
    }

    // MARK: 2. Wildcard roots

    @Test
    func wildcardRootSkipsADeniedContainerAndReportsIt() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        for container in ["A", "B", "C"] {
            try fixture.file("Library/Containers/\(container)/Data/Library/Caches/blob.bin", pages: 2)
        }
        try fixture.tree.setPermissions("home/Library/Containers/C", mode: 0o000)

        let rule = makeRule("test.containers", roots: [["Library", "Containers", "*", "Data", "Library", "Caches"]])
        let (_, report) = await fixture.scan([rule])
        let result = try #require(fixture.result("test.containers", in: report))

        #expect(result.findings.map(\.name) == ["blob.bin", "blob.bin"])
        #expect(Set(result.findings.map { $0.url.pathComponents.dropLast(4).last }) == ["A", "B"])
        #expect(result.needsAccess.count == 1)
        #expect(result.needsAccess.first?.path.contains("/Containers/C") == true)
        #expect(result.measuredBytes == fixture.bytes(4))
    }

    @Test
    func deniedRootIsNeedsAccessNotZeroBytes() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Caches/com.a.App/one.bin", pages: 2)
        try fixture.tree.setPermissions("home/Library/Caches", mode: 0o000)

        let (_, report) = await fixture.scan([makeRule("test.caches", roots: [["Library", "Caches"]])])
        let result = try #require(fixture.result("test.caches", in: report))

        #expect(result.findings.isEmpty)
        #expect(result.needsAccess.map(\.lastPathComponent) == ["Caches"])
        #expect(result.missingRoots.isEmpty)
    }

    @Test
    func wildcardIgnoresFilesAndSymlinksAndStaysInsideTheParent() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Containers/A/Caches/real.bin", pages: 1)
        try fixture.file("Library/Containers/file.txt", pages: 1)
        let elsewhere = fixture.tree.url(for: "elsewhere")
        try fixture.tree.addFile("elsewhere/Caches/secret.bin", size: EngineFixture.page)
        try fixture.tree.addSymlink("home/Library/Containers/Linked", destination: elsewhere)

        let rule = makeRule("test.containers", roots: [["Library", "Containers", "*", "Caches"]])
        let (_, report) = await fixture.scan([rule])
        let result = try #require(fixture.result("test.containers", in: report))

        #expect(result.findings.map(\.name) == ["real.bin"])
        #expect(result.needsAccess.isEmpty)
    }

    // MARK: 3. Protected

    @Test
    func protectedChildIsSkipped() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Caches/com.a.App/one.bin")
        try fixture.file("Library/Caches/CloudKit/db.bin")
        try fixture.file("Library/Caches/com.apple.Spotlight/index.bin")

        let (_, report) = await fixture.scan([makeRule("test.caches", roots: [["Library", "Caches"]])])
        let result = try #require(fixture.result("test.caches", in: report))

        #expect(result.findings.map(\.name) == ["com.a.App"])
        #expect(result.skippedCounts[.protectedPath] == 2)
    }

    @Test
    func userExclusionWins() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Caches/com.a.App/one.bin")
        try fixture.file("Library/Caches/com.b.App/one.bin")

        let rule = makeRule("test.caches", roots: [["Library", "Caches"]])
        let (_, report) = await fixture.scan([rule], exclusions: [fixture.url("Library/Caches/com.b.App")])
        let result = try #require(fixture.result("test.caches", in: report))

        #expect(result.findings.map(\.name) == ["com.a.App"])
        #expect(result.skippedCounts[.protectedPath] == 1)
    }

    // MARK: 4. Age

    @Test
    func minAgeOffersOnlyOldChildren() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Caches/old.App/a.bin", modified: fixture.days(20))
        try fixture.tree.setModified("home/Library/Caches/old.App", to: fixture.days(20))
        try fixture.file("Library/Caches/mixed.App/old.bin", modified: fixture.days(30))
        try fixture.file("Library/Caches/mixed.App/new.bin", modified: fixture.days(1))
        try fixture.tree.setModified("home/Library/Caches/mixed.App", to: fixture.days(30))
        try fixture.file("Library/Caches/new.App/b.bin", modified: fixture.days(1))

        let rule = makeRule("test.caches", roots: [["Library", "Caches"]], guards: Guards(minAge: week))
        let (_, report) = await fixture.scan([rule])
        let result = try #require(fixture.result("test.caches", in: report))

        #expect(result.findings.map(\.name) == ["old.App"])
        #expect(result.skippedCounts[.tooNew] == 2)
    }

    @Test
    func unreadableFolderInsideAnAgeGuardedItemKeepsItSafe() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Caches/clean.App/a.bin", modified: fixture.days(20))
        try fixture.tree.setModified("home/Library/Caches/clean.App", to: fixture.days(20))
        try fixture.file("Library/Caches/locked.App/open.bin", modified: fixture.days(20))
        try fixture.file("Library/Caches/locked.App/hidden/x.bin", modified: fixture.days(1))
        // The folder's own date is old; only the file inside (which the walk cannot read) is new.
        try fixture.tree.setModified("home/Library/Caches/locked.App/hidden", to: fixture.days(20))
        try fixture.tree.setModified("home/Library/Caches/locked.App", to: fixture.days(20))
        try fixture.tree.setPermissions("home/Library/Caches/locked.App/hidden", mode: 0o000)

        let rule = makeRule("test.caches", roots: [["Library", "Caches"]], guards: Guards(minAge: week))
        let (_, report) = await fixture.scan([rule])
        let result = try #require(fixture.result("test.caches", in: report))

        // The unreadable folder may hold new files, so the age of locked.App is unknown.
        #expect(result.findings.map(\.name) == ["clean.App"])
        #expect(result.skippedCounts[.unknownAge] == 1)
        #expect(result.needsAccess.map(\.lastPathComponent) == ["hidden"])
    }

    // MARK: 5. Keep newest

    @Test
    func keepNewestKeepsTheNewestTwo() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        let base = "Library/Developer/Xcode/iOS DeviceSupport"
        for (index, version) in ["17.0", "17.1", "17.2", "17.3"].enumerated() {
            let date = fixture.days(Double(40 - index * 10))
            try fixture.file("\(base)/\(version)/symbols.bin", modified: date)
            try fixture.tree.setModified("home/\(base)/\(version)", to: date)
        }

        let rule = makeRule(
            "test.deviceSupport", roots: [["Library", "Developer", "Xcode", "iOS DeviceSupport"]],
            guards: Guards(keepNewest: 2))
        let (_, report) = await fixture.scan([rule])
        let result = try #require(fixture.result("test.deviceSupport", in: report))

        #expect(result.findings.map(\.name) == ["17.0", "17.1"])
        #expect(result.skippedCounts[.keepNewest] == 2)
    }

    // MARK: 6. Files and glob

    @Test
    func filesRuleFindsExtensionsCaseInsensitivelyWithinDepth() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/iTunes/iPhone Software Updates/a.ipsw", pages: 2)
        try fixture.file("Library/iTunes/B.IPSW", pages: 3)
        try fixture.file("Library/iTunes/iPhone Software Updates/notes.txt")
        try fixture.file("Library/iTunes/iPhone Software Updates/deeper/c.ipsw")
        try fixture.tree.addDirectory("home/Library/iTunes/folder.ipsw")

        let rule = makeRule(
            "test.firmware", roots: [["Library", "iTunes"]], match: .files(extensions: ["ipsw"]), depth: 2)
        let (_, report) = await fixture.scan([rule])
        let result = try #require(fixture.result("test.firmware", in: report))

        #expect(Set(result.findings.map(\.name)) == ["a.ipsw", "B.IPSW"])
        #expect(result.measuredBytes == fixture.bytes(5))
        #expect(result.findings.allSatisfy { !$0.isDirectory })
    }

    @Test
    func globRuleMatchesBelowTheRootAtAnyDepth() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Logs/a.log")
        try fixture.file("Library/Logs/sub/b.log")
        try fixture.file("Library/Logs/sub/deep/c.log")
        try fixture.file("Library/Logs/sub/deep/d.txt")
        try fixture.file("Library/Logs/sub/deep/deeper/e.log")

        let rule = makeRule("test.logs", roots: [["Library", "Logs"]], match: .glob("**/*.log"), depth: 3)
        let (_, report) = await fixture.scan([rule])
        let result = try #require(fixture.result("test.logs", in: report))

        #expect(Set(result.findings.map(\.name)) == ["a.log", "b.log", "c.log"])
    }

    // MARK: 7. Measure only

    @Test
    func infoRuleMeasuresItsRootAndOffersNothing() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Mail/V10/box.bin", pages: 3)
        try fixture.file("Library/Messages/Attachments/pic.bin", pages: 2)

        let measure = makeRule("test.mail", tier: .info, roots: [["Library", "Mail"]], match: .measureOnly)
        // An Info rule is measured even when it names another match kind.
        let children = makeRule("test.messages", tier: .info, roots: [["Library", "Messages"]])
        let (_, report) = await fixture.scan([measure, children])

        let mail = try #require(fixture.result("test.mail", in: report))
        #expect(mail.findings.isEmpty)
        #expect(mail.measuredBytes == fixture.bytes(3))
        #expect(mail.measuredBytes > 0)
        #expect(mail.skippedCounts.isEmpty)
        let messages = try #require(fixture.result("test.messages", in: report))
        #expect(messages.findings.isEmpty)
        #expect(messages.measuredBytes == fixture.bytes(2))
    }

    @Test
    func ownerCommandRuleIsNotWalked() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Caches/com.a.App/one.bin")
        let command = OwnerCommandSpec(
            id: "test.command", executable: URL(filePath: "/usr/bin/true"), arguments: [], timeout: .seconds(1))
        let rule = makeRule("test.command", roots: [["Library", "Caches"]], match: .ownerCommand(command))
        let (events, report) = await fixture.scan([rule])
        let result = try #require(fixture.result("test.command", in: report))

        #expect(result.findings.isEmpty)
        #expect(result.measuredBytes == 0)
        #expect(result.partial == false)
        #expect(events.contains { if case .ruleStarted("test.command") = $0 { true } else { false } })
    }

    // MARK: 8. Missing roots

    @Test
    func missingRootIsReportedNotThrown() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Caches/com.a.App/one.bin")

        let rule = makeRule("test.missing", roots: [["Library", "Nope"], ["Library", "Caches"]])
        let (_, report) = await fixture.scan([rule])
        let result = try #require(fixture.result("test.missing", in: report))

        #expect(result.missingRoots.map(\.lastPathComponent) == ["Nope"])
        #expect(result.findings.map(\.name) == ["com.a.App"])
        #expect(result.partial == false)
    }

    // MARK: 9. Overlap

    @Test
    func firstRuleInRequestOrderKeepsAPath() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Caches/com.a.App/one.bin", pages: 2)

        let first = makeRule("test.first", roots: [["Library", "Caches"]])
        let second = makeRule("test.second", roots: [["Library", "Caches"]])

        let (_, report) = await fixture.scan([first, second])
        #expect(report.results.map(\.ruleID) == ["test.first", "test.second"])
        #expect(report.results[0].findings.count == 1)
        #expect(report.results[1].findings.isEmpty)
        #expect(report.results[1].measuredBytes == 0)
        #expect(report.duplicatesDropped == 1)

        let (_, reversed) = await fixture.scan([second, first])
        #expect(reversed.results.map(\.ruleID) == ["test.second", "test.first"])
        #expect(reversed.results[0].findings.count == 1)
        #expect(reversed.results[1].findings.isEmpty)
        #expect(reversed.duplicatesDropped == 1)
    }

    @Test
    func overlappingRootsOfOneRuleDoNotDuplicateFindings() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Caches/com.a.App/one.bin", pages: 2)

        let rule = makeRule("test.twice", roots: [["Library", "Caches"], ["Library", "Caches"]])
        let (_, report) = await fixture.scan([rule])
        #expect(report.results[0].findings.count == 1)
        #expect(report.duplicatesDropped == 1)
    }

    // MARK: 10. Required sibling

    @Test
    func requiresSiblingKeepsOnlyTargetsBesideCargoToml() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Projects/p1/Cargo.toml")
        try fixture.file("Projects/p1/target/debug/x.bin", pages: 2)
        try fixture.file("Projects/p2/target/debug/y.bin", pages: 2)
        try fixture.file("Projects/p2/notes.md")

        let rule = makeRule(
            "test.cargo", roots: [["Projects"]], match: .glob("*/target"), depth: 2,
            guards: Guards(requiresSibling: ["Cargo.toml"]))
        let (_, report) = await fixture.scan([rule])
        let result = try #require(fixture.result("test.cargo", in: report))

        #expect(result.findings.map { $0.url.deletingLastPathComponent().lastPathComponent } == ["p1"])
        #expect(result.findings.first?.name == "target")
        #expect(result.findings.first?.allocatedBytes == fixture.bytes(2))
        #expect(result.skippedCounts[.missingSibling] == 1)
    }

    // MARK: 12. Symlinks

    @Test
    func symlinkChildPointingOutsideIsNeverFollowed() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Caches/real.App/a.bin", pages: 1)
        let outside = fixture.tree.url(for: "outside")
        try fixture.tree.addFile("outside/big.bin", size: 10 * EngineFixture.page)
        try fixture.tree.addSymlink("home/Library/Caches/link.App", destination: outside)

        // `.children` may offer the link itself. Its target is not read: 0 bytes.
        let children = makeRule("test.children", roots: [["Library", "Caches"]])
        // Other match kinds never offer a symlink. (Separate scan: the same paths would be dropped as duplicates.)
        let glob = makeRule("test.glob", roots: [["Library", "Caches"]], match: .glob("*"))
        let (_, report) = await fixture.scan([children])
        let (_, globReport) = await fixture.scan([glob])

        let offered = try #require(fixture.result("test.children", in: report))
        let link = try #require(offered.findings.first { $0.name == "link.App" })
        #expect(link.isSymlink)
        #expect(link.allocatedBytes == 0)
        #expect(offered.measuredBytes == fixture.bytes(1))

        let globbed = try #require(fixture.result("test.glob", in: globReport))
        #expect(globbed.findings.map(\.name) == ["real.App"])
        #expect(globbed.skippedCounts[.symlinkNotAllowed] == 1)
    }

    @Test
    func symlinkIsNotOfferedByGlobOrFilesRules() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        let outside = fixture.tree.url(for: "outside")
        try fixture.tree.addFile("outside/big.bin", size: 10 * EngineFixture.page)
        try fixture.tree.addSymlink("home/Library/Caches/link.App", destination: outside)

        let glob = makeRule("test.glob", roots: [["Library", "Caches"]], match: .glob("*"))
        let (_, report) = await fixture.scan([glob])
        let result = try #require(fixture.result("test.glob", in: report))

        #expect(result.findings.isEmpty)
        #expect(result.skippedCounts[.symlinkNotAllowed] == 1)
        #expect(result.measuredBytes == 0)
    }

    @Test
    func symlinkedRootIsNotScanned() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.tree.addFile("elsewhere/Caches/x.bin", size: EngineFixture.page)
        try fixture.tree.addSymlink("home/Caches", destination: fixture.tree.url(for: "elsewhere/Caches"))

        let (_, report) = await fixture.scan([makeRule("test.link", roots: [["Caches"]])])
        let result = try #require(fixture.result("test.link", in: report))

        #expect(result.findings.isEmpty)
        #expect(result.missingRoots.map(\.lastPathComponent) == ["Caches"])
    }

    @Test
    func symlinkedAncestorBelowTheHomeIsNotScanned() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        // ~/Library points elsewhere. Resolving it would move the root out of the home folder, where
        // the home-relative protected list no longer applies, so the root is skipped instead.
        try fixture.tree.addFile("elsewhere/Library/Caches/CloudKit/db.bin", size: EngineFixture.page)
        try fixture.tree.addSymlink("home/Library", destination: fixture.tree.url(for: "elsewhere/Library"))

        let (_, report) = await fixture.scan([makeRule("test.link", roots: [["Library", "Caches"]])])
        let result = try #require(fixture.result("test.link", in: report))

        #expect(result.findings.isEmpty)
        #expect(result.missingRoots.count == 1)
    }

    @Test
    func symlinkedWildcardMatchAndTailAreNotScanned() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.tree.addFile("elsewhere/Data/Library/Caches/x.bin", size: EngineFixture.page)
        try fixture.file("Library/Containers/Good/Data/Library/Caches/ok.bin")
        // A matched container whose `Data` is a link.
        try fixture.tree.addDirectory("home/Library/Containers/Bad")
        try fixture.tree.addSymlink("home/Library/Containers/Bad/Data", destination: fixture.tree.url(for: "elsewhere/Data"))

        let rule = makeRule("test.containers", roots: [["Library", "Containers", "*", "Data", "Library", "Caches"]])
        let (_, report) = await fixture.scan([rule])
        let result = try #require(fixture.result("test.containers", in: report))

        #expect(result.findings.map(\.name) == ["ok.bin"])
    }

    // MARK: Cancellation

    @Test
    func cancellingStopsTheWalkAndMarksTheReportPartial() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        let tree = fixture.tree
        try await offPool {
            for index in 0..<20 {
                try tree.addEmptyFiles(in: "home/Library/Caches/dir\(index)", count: 1_000)
            }
        }

        let request = ScanRequest(
            rules: [makeRule("test.big", roots: [["Library", "Caches"]], match: .glob("*/f1"), depth: 2)],
            environment: fixture.environment)
        let sawProgress = Mutex(false)
        let finished = Mutex(false)
        let task = Task {
            let report = await ScanRun.execute(request) { event in
                if case .progress = event { sawProgress.withLock { $0 = true } }
            }
            finished.withLock { $0 = true }
            return report
        }
        // The walker reports once as soon as it starts, long before 20,000 files are read.
        while !sawProgress.withLock({ $0 }), !finished.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(1))
        }
        let clock = ContinuousClock()
        let cancelled = clock.now
        task.cancel()
        let report = await task.value
        let elapsed = cancelled.duration(to: clock.now)

        #expect(report.partial)
        #expect(report.results.count == 1)
        #expect(report.results[0].partial)
        #expect(elapsed < timingBudget(.milliseconds(200)))
    }

    @Test
    func cancellingTheStreamConsumerEndsPromptly() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        let tree = fixture.tree
        try await offPool {
            for index in 0..<4 {
                try tree.addEmptyFiles(in: "home/Library/Caches/dir\(index)", count: 500)
            }
        }
        let request = ScanRequest(
            rules: [makeRule("test.big", roots: [["Library", "Caches"]])], environment: fixture.environment)
        let engine = ScanEngine()
        let consumer = Task {
            var seen = 0
            for await _ in await engine.scan(request) {
                seen += 1
                if Task.isCancelled { break }
            }
            return seen
        }
        consumer.cancel()
        let clock = ContinuousClock()
        let started = clock.now
        _ = await consumer.value
        #expect(started.duration(to: clock.now) < timingBudget(.milliseconds(200)))
    }

    @Test
    func emptyRequestFinishesWithAnEmptyReport() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        let (events, report) = await fixture.scan([])
        #expect(report.results.isEmpty)
        #expect(report.partial == false)
        #expect(events.count == 1)
    }

    // MARK: Parallelism and progress

    @Test(arguments: [
        (8, 2, 4, 2, 4), (8, 4, 4, 4, 4), (8, 20, 8, 6, 6), (8, 0, 0, 1, 1), (4, 2, 4, 2, 4), (2, 2, 4, 2, 2),
        (14, 3, 8, 3, 6),
    ])
    func limitsClampRootsAndWorkersToTheThreadBudget(
        cores: Int, roots: Int, workers: Int, wantRoots: Int, wantWorkers: Int
    ) {
        let request = ScanRequest(
            rules: [], environment: Environment(home: URL(filePath: "/tmp", directoryHint: .isDirectory)),
            maxConcurrentRoots: roots, workersPerRoot: workers)
        let limits = ScanRun.Limits(request, cores: cores)
        #expect(limits == ScanRun.Limits(roots: wantRoots, workers: wantWorkers))
        #expect(limits.roots <= ScanRun.Limits.threadBudget(cores: cores))
        #expect(limits.workers <= ScanRun.Limits.threadBudget(cores: cores))
    }

    @Test
    func threadBudgetNeverExceedsTheCoresOrTheRuleOfEight() {
        #expect(ScanRun.Limits.threadBudget(cores: 1) == 1)
        #expect(ScanRun.Limits.threadBudget(cores: 4) == 4)
        #expect(ScanRun.Limits.threadBudget(cores: 64) <= 8)
        #expect(ScanRun.Limits.threadBudget(cores: 0) == 1)
    }

    @Test
    func manyRulesAndRootsAllFinishAndTheReportIsInRequestOrder() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        var rules: [Rule] = []
        for index in 0..<12 {
            try fixture.file("Library/Area\(index)/Caches/app.App/f.bin", pages: index + 1)
            rules.append(makeRule("test.rule\(index)", roots: [["Library", "Area\(index)", "Caches"]]))
        }

        let (events, report) = await fixture.scan(rules, roots: 3, workers: 2)

        // The report is in request order, whatever order the rules finished in.
        #expect(report.results.map(\.ruleID) == rules.map(\.id))
        for (index, result) in report.results.enumerated() {
            #expect(result.measuredBytes == fixture.bytes(index + 1))
        }
        // The rules do not share any path, so they may arrive in any order. Each arrives once.
        let finished = events.compactMap { event -> String? in
            if case .ruleFinished(let result) = event { result.ruleID } else { nil }
        }
        #expect(finished.sorted() == rules.map(\.id).sorted())
        let started = events.compactMap { event -> String? in
            if case .ruleStarted(let id) = event { id } else { nil }
        }
        #expect(started.sorted() == rules.map(\.id).sorted())
        if case .finished = events.last {} else { Issue.record("`.finished` is not the last event") }
    }

    // MARK: excludeRootSegments

    @Test
    func excludedWildcardFoldersAreNeitherWalkedNorProbed() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        for container in ["com.apple.Notes", "com.example.A", "com.example.B"] {
            try fixture.file("Library/Containers/\(container)/Data/Library/Caches/blob.bin", pages: 2)
        }
        // macOS would refuse this one. The engine must not even try to open it.
        try fixture.tree.setPermissions("home/Library/Containers/com.apple.Notes", mode: 0o000)

        let guards = Guards(excludeRootSegments: ["com.apple.*"])
        let rule = makeRule(
            "test.containers", roots: [["Library", "Containers", "*", "Data", "Library", "Caches"]], guards: guards)
        let (_, report) = await fixture.scan([rule])
        let result = try #require(fixture.result("test.containers", in: report))

        #expect(result.findings.map(\.name) == ["blob.bin", "blob.bin"])
        #expect(Set(result.findings.map { $0.url.pathComponents.dropLast(4).last }) == ["com.example.A", "com.example.B"])
        #expect(result.measuredBytes == fixture.bytes(4))
        #expect(result.excludedRoots.map(\.lastPathComponent) == ["com.apple.Notes"])
        #expect(result.needsAccess.isEmpty)
        #expect(result.missingRoots.isEmpty)
        #expect(result.partial == false)
    }

    @Test
    func catalogContainerRulesLeaveAppleFoldersOut() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        for container in ["com.apple.Notes", "com.example.A", "com.example.B"] {
            try fixture.file("Library/Containers/\(container)/Data/Library/Caches/blob.bin", pages: 1)
        }
        for group in ["group.com.apple.notes", "systemgroup.com.apple.x", "ABCDE12345.com.apple.y", "group.com.example.z"] {
            try fixture.file("Library/Group Containers/\(group)/Library/Caches/blob.bin", pages: 1)
        }
        let containers = try #require(Catalog.all.first { $0.id == "user.containerCaches" })
        let groups = try #require(Catalog.all.first { $0.id == "user.groupContainerCaches" })

        let (_, report) = await fixture.scan([containers, groups])
        let containerResult = try #require(fixture.result(containers.id, in: report))
        let groupResult = try #require(fixture.result(groups.id, in: report))

        // `<container>/Data/Library/Caches/blob.bin` and `<group>/Library/Caches/blob.bin`.
        func owners(_ result: RuleResult, above levels: Int) -> [String] {
            result.findings.map { $0.url.pathComponents.dropLast(levels).last ?? "" }
        }
        #expect(owners(containerResult, above: 4) == ["com.example.A", "com.example.B"])
        #expect(containerResult.excludedRoots.map(\.lastPathComponent) == ["com.apple.Notes"])
        #expect(owners(groupResult, above: 3) == ["group.com.example.z"])
        #expect(groupResult.excludedRoots.map(\.lastPathComponent)
            == ["ABCDE12345.com.apple.y", "group.com.apple.notes", "systemgroup.com.apple.x"])
    }

    @Test
    func ruleWithoutExcludeRootSegmentsReportsNoExcludedRoots() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Containers/com.apple.Maps/Data/Library/Caches/blob.bin", pages: 1)
        let rule = makeRule("test.containers", roots: [["Library", "Containers", "*", "Data", "Library", "Caches"]])
        let (_, report) = await fixture.scan([rule])
        let result = try #require(fixture.result("test.containers", in: report))
        #expect(result.excludedRoots.isEmpty)
        #expect(result.findings.count == 1)
    }
}
