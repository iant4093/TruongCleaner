import CleanerCore
import Foundation
import Synchronization
import Testing
@testable import CleanerScanner

/// The fast scan (`ScanRun.Tuning.standard`) must find exactly what the plain engine finds
/// (`Tuning.reference`: fixed share of threads, request order, no glob filter). Task 2.7.
struct ScanEquivalenceTests {
    /// A home folder with something under every kind of root the rules below use.
    private func populate(_ fixture: EngineFixture) throws {
        let old = fixture.days(60)
        func oldFile(_ path: String, pages: Int = 1) throws {
            try fixture.file(path, pages: pages, modified: old)
        }
        // Caches (children rule, with a nested rule root and an excluded name)
        try oldFile("Library/Caches/com.a.App/one.bin", pages: 2)
        try oldFile("Library/Caches/com.a.App/deep/er/two.bin", pages: 3)
        try oldFile("Library/Caches/com.b.App/three.bin", pages: 1)
        try oldFile("Library/Caches/Google/g.bin", pages: 4)
        try oldFile("Library/Caches/com.apple.dt.Xcode/Data/x.bin", pages: 5)
        try oldFile("Library/Caches/com.apple.QuickLook.thumbnailcache/t1.bin", pages: 1)
        try oldFile("Library/Caches/com.apple.QuickLook.thumbnailcache/t2.bin", pages: 2)
        try fixture.file("Library/Caches/loose.bin", pages: 1)
        // Hard links inside one item are counted once. (Across items the walk may charge either one.)
        let hardLinked = try fixture.file("Library/Caches/com.b.App/hl.bin", pages: 2, modified: old)
        _ = try fixture.tree.addHardLink("home/Library/Caches/com.b.App/hl-twin.bin", to: hardLinked)
        // Logs (files rule with depth and age)
        try oldFile("Library/Logs/App/old.log")
        try oldFile("Library/Logs/App/nested/older.log", pages: 2)
        try fixture.file("Library/Logs/App/new.log")
        try oldFile("Library/Logs/DiagnosticReports/crash.ips")
        // Downloads (files and glob rules)
        try oldFile("Downloads/a.dmg", pages: 3)
        try oldFile("Downloads/b.pkg")
        try oldFile("Downloads/c.crdownload", pages: 2)
        try oldFile("Downloads/Folder.download/part", pages: 2)
        try oldFile("Downloads/Sub/inner.dmg")
        try fixture.file("Downloads/fresh.dmg")
        // Archives (two-level glob; non-matching folders hold data the filter must not need)
        try oldFile("Library/Developer/Xcode/Archives/2024-01-01/App.xcarchive/Products/app.bin", pages: 6)
        try oldFile("Library/Developer/Xcode/Archives/2024-01-01/Notes/big.bin", pages: 7)
        try oldFile("Library/Developer/Xcode/Archives/2024-02-02/B.xcarchive/Info.plist")
        try oldFile("Library/Developer/Xcode/Archives/Other/readme.txt")
        // Installer apps (one-level glob with an age guard; the other app is not a match)
        try oldFile("Applications/Install macOS Test.app/Contents/payload.bin", pages: 8)
        try oldFile("Applications/Install macOS Old.app/Contents/Resources/x.bin", pages: 2)
        try oldFile("Applications/Safari.app/Contents/MacOS/Safari", pages: 9)
        try oldFile("Applications/Utilities/Terminal.app/Contents/t.bin", pages: 3)
        // A symlink out of a root and an empty folder
        let outside = try fixture.tree.addDirectory("outside")
        _ = try fixture.tree.addSymlink("home/Library/Caches/link", destination: outside)
        _ = try fixture.tree.addDirectory("home/Library/Caches/empty")
        try makeFoldersOld(fixture)
    }

    /// Folders get the old date too, so that age guards look at the files only. Files keep their own.
    private func makeFoldersOld(_ fixture: EngineFixture) throws {
        let old = fixture.days(60)
        var folders: [URL] = []
        if let walker = FileManager.default.enumerator(
            at: fixture.home, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            for case let url as URL in walker {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true, values.isSymbolicLink != true { folders.append(url) }
            }
        }
        // Deepest first, so that setting a folder's date is not undone by a change inside it.
        for folder in folders.sorted(by: { $0.path.count > $1.path.count }) {
            let relative = String(folder.path.dropFirst(fixture.home.path.count + 1))
            try fixture.tree.setModified("home/" + relative, to: old)
        }
    }

    private func rules() throws -> [Rule] {
        var rules: [Rule] = []
        for id in ["user.caches", "user.quickLook", "dev.xcodeCaches", "logs.user", "logs.userCrash",
                   "installers.downloads", "installers.partial", "dev.xcodeArchives"] {
            rules.append(try #require(Catalog.all.first { $0.id == id }))
        }
        rules.append(makeRule(
            "test.installer", roots: [["Applications"]], match: .glob("Install macOS*.app"),
            guards: Guards(minAge: .seconds(14 * 86_400))))
        rules.append(makeRule("test.apps", tier: .info, roots: [["Applications"]], match: .measureOnly))
        rules.append(makeRule("test.missing", roots: [["Library", "Nowhere"]]))
        return rules
    }

    private func compare(_ plain: ScanReport, _ fast: ScanReport) {
        #expect(fast.results.map(\.ruleID) == plain.results.map(\.ruleID))
        #expect(fast.duplicatesDropped == plain.duplicatesDropped)
        #expect(fast.partial == plain.partial)
        for (before, after) in zip(plain.results, fast.results) {
            let name = before.ruleID
            #expect(after.findings.map(\.url.path) == before.findings.map(\.url.path), "\(name) paths")
            #expect(after.findings.map(\.allocatedBytes) == before.findings.map(\.allocatedBytes), "\(name) bytes")
            #expect(after.findings.map(\.privateBytes) == before.findings.map(\.privateBytes), "\(name) private")
            #expect(after.findings.map(\.itemCount) == before.findings.map(\.itemCount), "\(name) items")
            #expect(after.findings.map(\.fileID) == before.findings.map(\.fileID), "\(name) file IDs")
            #expect(after.findings.map(\.fsid) == before.findings.map(\.fsid), "\(name) volumes")
            #expect(after.findings.map(\.isDirectory) == before.findings.map(\.isDirectory), "\(name) kinds")
            #expect(after.findings.map(\.newestModification) == before.findings.map(\.newestModification), "\(name) dates")
            #expect(after.measuredBytes == before.measuredBytes, "\(name) measured")
            #expect(after.measuredPrivateBytes == before.measuredPrivateBytes, "\(name) measured private")
            #expect(after.skippedCounts == before.skippedCounts, "\(name) skipped")
            #expect(after.needsAccess == before.needsAccess, "\(name) needs access")
            #expect(after.missingRoots == before.missingRoots, "\(name) missing")
            #expect(after.excludedRoots == before.excludedRoots, "\(name) excluded")
            #expect(after.partial == before.partial, "\(name) partial")
        }
    }

    @Test
    func theFastScanFindsWhatThePlainScanFinds() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try populate(fixture)
        let request = ScanRequest(rules: try rules(), environment: fixture.environment)

        let plain = await ScanRun.execute(request, tuning: .reference, cores: 8) { _ in }
        let fast = await ScanRun.execute(request, tuning: .standard, cores: 8) { _ in }

        compare(plain, fast)
        // The fixture is not empty: something was found by every kind of rule.
        let byID = Dictionary(uniqueKeysWithValues: fast.results.map { ($0.ruleID, $0) })
        #expect(byID["user.caches"]?.findings.isEmpty == false)
        #expect(byID["logs.user"]?.findings.isEmpty == false)
        #expect(byID["installers.downloads"]?.findings.isEmpty == false)
        #expect(byID["installers.partial"]?.findings.isEmpty == false)
        #expect(byID["dev.xcodeArchives"]?.findings.count == 2)
        #expect(byID["test.installer"]?.findings.map(\.name) == ["Install macOS Old.app", "Install macOS Test.app"])
        #expect(byID["test.installer"]?.measuredBytes == fixture.bytes(8 + 2))
        #expect(byID["test.apps"]?.measuredBytes == fixture.bytes(8 + 2 + 9 + 3))
    }

    @Test(arguments: [1, 2, 4, 14])
    func theResultDoesNotDependOnTheNumberOfCores(cores: Int) async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try populate(fixture)
        let request = ScanRequest(rules: try rules(), environment: fixture.environment)

        let plain = await ScanRun.execute(request, tuning: .reference, cores: 8) { _ in }
        let fast = await ScanRun.execute(request, tuning: .standard, cores: cores) { _ in }

        compare(plain, fast)
    }

    @Test
    func everyTuningSwitchAloneKeepsTheResult() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try populate(fixture)
        let request = ScanRequest(rules: try rules(), environment: fixture.environment)
        let plain = await ScanRun.execute(request, tuning: .reference, cores: 8) { _ in }

        var elastic = ScanRun.Tuning.reference
        elastic.elasticWorkers = true
        var descent = ScanRun.Tuning.reference
        descent.globDescent = true
        var ordered = ScanRun.Tuning.reference
        ordered.largestFirst = true
        var early = ScanRun.Tuning.reference
        early.deliverEarly = true
        for tuning in [elastic, descent, ordered, early] {
            let report = await ScanRun.execute(request, tuning: tuning, cores: 8) { _ in }
            compare(plain, report)
        }
    }

    @Test
    func theGlobFilterReadsFewerFilesThanThePlainWalk() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try populate(fixture)
        let rule = makeRule(
            "test.installer", roots: [["Applications"]], match: .glob("Install macOS*.app"),
            guards: Guards(minAge: .seconds(14 * 86_400)))
        let request = ScanRequest(rules: [rule], environment: fixture.environment)

        func filesCounted(_ tuning: ScanRun.Tuning) async -> Int {
            let last = Mutex(0)
            _ = await ScanRun.execute(request, tuning: tuning, cores: 8) { event in
                if case .progress(let files, _) = event { last.withLock { $0 = files } }
            }
            return last.withLock { $0 }
        }
        // Progress is throttled, so compare the walks themselves.
        var options = WalkOptions(maxWorkers: 2, totalsDepth: 1)
        let all = try await BulkWalker.walk(fixture.url("Applications"), options: options)
        options.descent = DescentFilter(rule: rule)
        let some = try await BulkWalker.walk(fixture.url("Applications"), options: options)

        #expect(all.files == 4)
        #expect(some.files == 2)
        _ = await filesCounted(.standard)
    }
}
