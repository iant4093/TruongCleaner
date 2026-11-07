import CleanerCore
import CleanerTestSupport
import Darwin
import Foundation
import Testing

@testable import CleanerActions

/// An APFS disk image attached for the length of a test. Everything the test trashes lands in the
/// image's own `.Trashes/<uid>`, never in `~/.Trash`.
///
/// The image mounts under `/Volumes`, not inside the fixture: spike S3 showed that macOS creates
/// `.Trashes/<uid>` only for volumes mounted there, and `trashItem` fails (Cocoa 513) elsewhere.
private struct AttachedImage {
    struct Unavailable: Error, CustomStringConvertible {
        let description: String
    }

    let volume: URL
    private let log: URL

    /// Creates and attaches an image. Throws `Unavailable` if either step fails.
    static func attach(in tree: FixtureTree) async throws -> AttachedImage {
        let image = tree.url(for: "executor.sparseimage")
        let log = tree.url(for: "hdiutil.log")
        let name = "TCClean\(UUID().uuidString.prefix(8))"
        _ = try await hdiutil(["create", "-size", "50m", "-type", "SPARSE", "-fs", "APFS", "-volname", name, image.path], log: log)
        let output = try await hdiutil(["attach", "-nobrowse", "-noverify", "-noautofsck", "-plist", image.path], log: log)
        guard let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]],
            let mount = entities.compactMap({ $0["mount-point"] as? String }).first
        else { throw Unavailable(description: "attach gave no mount point") }
        return AttachedImage(volume: URL(filePath: mount, directoryHint: .isDirectory), log: log)
    }

    func detach() async {
        for attempt in 0..<3 {
            if (try? await Self.hdiutil(["detach", volume.path, attempt == 2 ? "-force" : "-quiet"], log: log)) != nil {
                return
            }
        }
    }

    /// Runs `hdiutil` without blocking a thread: output goes to a file and the exit is awaited.
    private static func hdiutil(_ arguments: [String], log: URL) async throws -> Data {
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
            throw Unavailable(description: "cannot create log")
        }
        let sink = try FileHandle(forWritingTo: log)
        defer { try? sink.close() }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = sink
        process.standardError = sink
        process.standardInput = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        let output = (try? Data(contentsOf: log)) ?? Data()
        guard status == 0 else {
            throw Unavailable(description: "hdiutil \(arguments.first ?? "") failed: \(String(decoding: output.prefix(200), as: UTF8.self))")
        }
        return output
    }
}

struct DiskImageExecutorTests {
    @Test func fileManagerExecutor_movesAndRestoresAndFreesOnARealVolume() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }

        let image: AttachedImage
        do {
            image = try await AttachedImage.attach(in: tree)
        } catch {
            withKnownIssue("Could not attach a disk image here: \(error)") { throw error }
            return
        }
        // Detach before the fixture is removed, whether the scenario passes, fails or throws.
        do {
            try await scenario(on: image, tree: tree)
        } catch {
            await image.detach()
            throw error
        }
        await image.detach()
    }

    private func scenario(on image: AttachedImage, tree: FixtureTree) async throws {
        // Home and rule root live on the image. The history file stays in the fixture.
        let home = image.volume.appending(path: "home", directoryHint: .isDirectory)
        let caches = home.appending(path: "Library/Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let fileURLs = ["a.bin", "b.bin"].map { caches.appending(path: $0) }
        for url in fileURLs { try Data(count: 4096).write(to: url) }
        let foreign = caches.appending(path: "keep-in-trash.bin")
        try Data(count: 10).write(to: foreign)

        let environment = Environment(home: home, now: Date())
        let context = GateContext(
            environment: environment,
            policy: PathPolicy(environment: environment, userExclusions: []),
            expandedRoots: [caches],
            runningApps: FakeApps(),
            openFiles: FakeFiles(answer: false))
        let rule = Rule(
            id: "test.rule", category: .caches, tier: .safe,
            roots: [RootSpec(base: .home, components: ["Library", "Caches"])], match: .children,
            guards: Guards(), access: .user, action: .trash, title: "Test", explain: "Test rule")
        let items = try (fileURLs + [foreign]).map { url -> PlannedItem in
            let identity = try GateSystem.identity(of: url)
            let finding = Finding(
                ruleID: "test.rule", url: url, fsid: identity.fsid, fileID: identity.fileID, allocatedBytes: 4096,
                privateBytes: 4096, newestModification: nil, isDirectory: false, isSymlink: false, flags: 0,
                itemCount: 1)
            return PlannedItem(finding: finding, rule: rule, expandedRoots: [caches])
        }

        let history = HistoryStore(fileURL: tree.url(for: "state/history.jsonl"))
        let cleaner = Cleaner(
            gate: SafetyGate(), executor: FileManagerExecutor(), history: history,
            context: { _ in context }, openFilesSource: { FakeFiles(answer: false) })
        // Clean the first two files; keep `foreign` out of the plan so it stays where it is.
        let report = await cleaner.run(CleanPlan(items: Array(items.prefix(2))), progress: { _ in })

        // The image's Trash is `<volume>/.Trashes/<uid>`.
        let expectedTrash = image.volume.appending(path: ".Trashes/\(getuid())", directoryHint: .isDirectory)
        for (entry, url) in zip(report.items, fileURLs) {
            let trashed = try #require(entry.outcome.movedURL)
            #expect(trashed.deletingLastPathComponent().resolvingSymlinksInPath().path == expectedTrash.resolvingSymlinksInPath().path)
            #expect(!exists(url))
            #expect(exists(trashed))
            #expect(try GateSystem.identity(of: trashed).fileID == entry.fileID)
        }

        // A foreign file in the same Trash must survive Free Space Now.
        let foreignTrashed = expectedTrash.appending(path: "someone-elses.txt")
        try Data(count: 8).write(to: foreignTrashed)

        let undo = UndoService(trash: TrashLocations(home: home))
        let restored = await undo.putBack(report.items[0], cleanID: report.id, history: history)
        guard case .restored = restored else {
            Issue.record("Put Back failed: \(restored)")
            return
        }
        #expect(exists(fileURLs[0]))

        let freed = await undo.freeSpaceNow(history: history, executor: FileManagerExecutor())
        #expect(freed.freed.map(\.findingID) == [report.items[1].findingID])
        let freedURL = try #require(report.items[1].outcome.movedURL)
        #expect(!exists(freedURL))
        #expect(exists(foreignTrashed))
        #expect(exists(foreign))
        #expect(exists(fileURLs[0]))
    }

    @Test func fileManagerExecutor_permanentDeleteRemovesALinkWithoutTouchingItsTarget() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let target = try tree.addFile("target/keep.bin", size: 10)
        let link = try tree.addSymlink("links/link", destination: target.deletingLastPathComponent())

        try await FileManagerExecutor().deletePermanently(link)
        #expect(!exists(link))
        #expect(exists(target))
    }

    @Test func fileManagerExecutor_refusesRelativeAndNonFileURLs() async {
        let executor = FileManagerExecutor()
        await #expect(throws: ExecutorError.notAFileURL) {
            try await executor.deletePermanently(URL(string: "https://example.com/a")!)
        }
        await #expect(throws: ExecutorError.notAFileURL) {
            _ = try await executor.moveToTrash(URL(string: "relative/path")!)
        }
    }
}
