import CleanerCore
import CleanerTestSupport
import Darwin
import Foundation
import Synchronization
import Testing

@testable import CleanerActions

/// Runs a child process for the length of a test and ends it afterwards.
private final class Child: Sendable {
    let process = Process()
    private let state = ExitState()

    init(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil) throws {
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [state] _ in state.markExited() }
        try process.run()
    }

    /// Ends the child without waiting. Safe in a `defer`.
    func kill() {
        if process.isRunning { process.terminate() }
    }

    /// Ends the child and suspends until it has exited. Never blocks a thread.
    func stop() async {
        kill()
        await state.waitForExit()
    }
}

/// Exit state shared with the termination handler, which runs on a dispatch thread.
private final class ExitState: Sendable {
    private let storage = Mutex<(exited: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func markExited() {
        let waiters = storage.withLock { value -> [CheckedContinuation<Void, Never>] in
            value.exited = true
            defer { value.waiters = [] }
            return value.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func waitForExit() async {
        await withCheckedContinuation { continuation in
            let alreadyExited = storage.withLock { value -> Bool in
                if value.exited { return true }
                value.waiters.append(continuation)
                return false
            }
            if alreadyExited { continuation.resume() }
        }
    }
}

/// Opens a file read-only with close-on-exec, so a child process started by a parallel test
/// cannot inherit the descriptor and keep the file open after we close it.
private func openReadOnly(_ url: URL) throws -> Int32 {
    let descriptor = open(url.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return descriptor
}

/// Polls `check` for up to `seconds`, because a child needs a moment to open its files.
private func eventually(seconds: Double = 5, _ check: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await check() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await check()
}

struct LivenessProviderTests {
    // MARK: ProcessOpenFilesProvider

    @Test func openFiles_ownHandleIsSeenAndThenReleased() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let file = try tree.addFile("held.bin", size: 10)
        let provider = ProcessOpenFilesProvider(excludingPIDs: [])

        let descriptor = try openReadOnly(file)
        let whileOpen = await provider.hasOpenFiles(under: file)
        guard let whileOpen else {
            // proc_listpidspath fails in some sandboxes; say so instead of passing silently.
            Issue.record("proc_listpidspath returned no answer in this environment; open-file detection untested")
            close(descriptor)
            return
        }
        #expect(whileOpen)
        close(descriptor)
        // A test running in parallel may be spawning a child at this moment. Until its exec, the
        // child holds a copy of every descriptor, so "still open" can be briefly stale. That is the
        // safe direction; the answer must settle on `false`.
        #expect(await eventually { await provider.hasOpenFiles(under: file) == false })
    }

    @Test func openFiles_hardLinkToAnOpenFileIsFoundByIdentity() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let file = try tree.addFile("a/held.bin", size: 10)
        let link = try tree.addHardLink("b/other-name.bin", to: file)
        let descriptor = try openReadOnly(file)
        defer { close(descriptor) }
        // The open file is reached by another name; its (device, inode) is the same.
        #expect(await ProcessOpenFilesProvider(excludingPIDs: []).hasOpenFiles(under: link) == true)
    }

    @Test func openFiles_folderHeldOpenItselfIsFound() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let folder = try tree.addDirectory("held")
        let descriptor = open(folder.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        #expect(await ProcessOpenFilesProvider(excludingPIDs: []).hasOpenFiles(under: folder) == true)
    }

    @Test func openFiles_ownProcessIsIgnoredByDefault() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let file = try tree.addFile("held.bin", size: 10)
        let descriptor = try openReadOnly(file)
        defer { close(descriptor) }
        // Settles on `false` (see the note in the "own handle" test about parallel spawns).
        let provider = ProcessOpenFilesProvider()
        #expect(await eventually { await provider.hasOpenFiles(under: file) == false })
    }

    @Test func openFiles_anotherProcessHoldingAFileIsSeenForTheFileAndItsFolders() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let file = try tree.addFile("logs/deep/held.log", size: 10)
        let child = try Child("/usr/bin/tail", ["-f", file.path(percentEncoded: false)])
        defer { child.kill() }
        let provider = ProcessOpenFilesProvider()

        #expect(await eventually { await provider.hasOpenFiles(under: file) == true })
        // A file inside the folder is open, so the folder counts, at every level.
        #expect(await provider.hasOpenFiles(under: tree.url(for: "logs/deep")) == true)
        #expect(await provider.hasOpenFiles(under: tree.url(for: "logs")) == true)
        // An unrelated sibling does not.
        let other = try tree.addFile("other/idle.bin", size: 10)
        #expect(await provider.hasOpenFiles(under: other) == false)
        #expect(await provider.hasOpenFiles(under: tree.url(for: "other")) == false)

        await child.stop()
        #expect(await eventually { await provider.hasOpenFiles(under: file) == false })
    }

    @Test func openFiles_folderAnswersStayConsistentUnderChurn() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let file = try tree.addFile("logs/deep/held.log", size: 10)
        let child = try Child("/usr/bin/tail", ["-f", file.path(percentEncoded: false)])
        defer { child.kill() }
        let provider = ProcessOpenFilesProvider()
        #expect(await eventually { await provider.hasOpenFiles(under: file) == true })

        // 20 short-lived processes start and end while the questions are asked.
        let churn = Task {
            for _ in 0..<20 {
                guard let short = try? Child("/bin/sleep", ["0.05"]) else { continue }
                await short.stop()
            }
        }
        let questions = [file, tree.url(for: "logs/deep"), tree.url(for: "logs")]
        var wrong = 0
        for round in 0..<100 {
            // The holder never lets go, so `false` is always a wrong answer. `nil` (unknown) is allowed.
            if await provider.hasOpenFiles(under: questions[round % questions.count]) == false { wrong += 1 }
        }
        await churn.value
        #expect(wrong == 0)
        await child.stop()
    }

    @Test func openFiles_processWhoseCurrentFolderIsInsideTheItemCounts() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let inner = try tree.addDirectory("project/build")
        let child = try Child("/bin/sleep", ["30"], currentDirectory: inner)
        defer { child.kill() }
        let provider = ProcessOpenFilesProvider()

        #expect(await eventually { await provider.hasOpenFiles(under: tree.url(for: "project")) == true })
        #expect(await provider.hasOpenFiles(under: inner) == true)
    }

    @Test func openFiles_itemThatDoesNotExistIsUnknownNotFalse() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let answer = await ProcessOpenFilesProvider().hasOpenFiles(under: tree.root.appending(path: "nothing"))
        #expect(answer == nil)
    }

    // MARK: ProcessNameOwnerProvider

    @Test func owners_runningProcessIsFoundByExactName() async throws {
        let child = try Child("/bin/sleep", ["30"])
        defer { child.kill() }
        let provider = ProcessNameOwnerProvider()
        let item = URL(filePath: "/tmp/x")

        #expect(await eventually { await provider.state(of: .processName("sleep"), for: item) == .running })
        // Whole-name match: a prefix or a different case is not the process.
        #expect(await provider.state(of: .processName("slee"), for: item) == .notRunning)
        #expect(await provider.state(of: .processName("no-such-process-tc-xyz"), for: item) == .notRunning)
        #expect(await provider.state(of: .processName(""), for: item) == .unknown)
    }

    @Test func owners_processEndsAndIsNoLongerRunning() async throws {
        let child = try Child("/bin/sleep", ["30"])
        let provider = ProcessNameOwnerProvider()
        let item = URL(filePath: "/tmp/x")
        #expect(await eventually { await provider.state(of: .processName("sleep"), for: item) == .running })
        await child.stop()
        // Other tests may run their own `sleep`, so only check that the answer is a clean yes/no.
        let state = await provider.state(of: .processName("sleep"), for: item)
        #expect(state != .unknown)
    }

    @Test func owners_bundleIDsAreUnknownHere() async {
        let state = await ProcessNameOwnerProvider().state(of: .bundleID("com.example.Tool"), for: URL(filePath: "/tmp/x"))
        #expect(state == .unknown)
    }

    @Test func owners_childNameWithoutBundleShapeHasNoOwner() async {
        let root = URL(filePath: "/tmp/caches", directoryHint: .isDirectory)
        let provider = ProcessNameOwnerProvider(roots: [root])
        #expect(await provider.state(of: .childNameAsBundleID(stripSuffix: nil), for: root.appending(path: "plain/x")) == .notRunning)
        #expect(await provider.state(of: .childNameAsBundleID(stripSuffix: nil), for: root.appending(path: "a.b/x")) == .notRunning)
        #expect(await provider.state(of: .childNameAsBundleID(stripSuffix: nil), for: root.appending(path: "com.example.Tool/x")) == .unknown)
        #expect(await provider.state(of: .childNameAsBundleID(stripSuffix: nil), for: URL(filePath: "/elsewhere/com.a.b")) == .unknown)
    }

    @Test func owners_childNameCanStripASuffix() async {
        let root = URL(filePath: "/tmp/saved", directoryHint: .isDirectory)
        let provider = ProcessNameOwnerProvider(roots: [root])
        let owner = OwnerSpec.childNameAsBundleID(stripSuffix: ".savedState")
        // "a.b.savedState" is "a.b" after stripping: not a bundle ID, so no owner.
        #expect(await provider.state(of: owner, for: root.appending(path: "a.b.savedState/x")) == .notRunning)
        #expect(await provider.state(of: owner, for: root.appending(path: "com.example.Tool.savedState/x")) == .unknown)
    }

    @Test func owners_rootSegmentNeedsTheRootSpecs() async {
        let specs = [RootSpec(base: .home, components: ["Library", "Containers", "*", "Data"])]
        let root = URL(filePath: "/tmp/h/Library/Containers/com.example.Tool/Data", directoryHint: .isDirectory)
        let plain = URL(filePath: "/tmp/h/Library/Containers/plain/Data", directoryHint: .isDirectory)
        let owner = OwnerSpec.rootSegmentAsBundleID(index: 2)
        let provider = ProcessNameOwnerProvider(roots: [root, plain], rootSpecs: specs)
        // A segment that is not a bundle ID has no owner. A bundle ID cannot be matched to a process.
        #expect(await provider.state(of: owner, for: plain.appending(path: "x")) == .notRunning)
        #expect(await provider.state(of: owner, for: root.appending(path: "x")) == .unknown)
        // Without specs or without a known root, the answer is unknown.
        let blind = ProcessNameOwnerProvider(roots: [root, plain])
        #expect(await blind.state(of: owner, for: plain.appending(path: "x")) == .unknown)
        #expect(await provider.state(of: owner, for: URL(filePath: "/elsewhere/x")) == .unknown)
    }

    // MARK: CompositeOwnerProvider

    @Test func composite_firstDefiniteAnswerWins() async {
        let item = URL(filePath: "/tmp/x")
        let owner = OwnerSpec.bundleID("com.example.Tool")

        let unsure = FakeApps(fallback: .unknown)
        let running = FakeApps(fallback: .running)
        let idle = FakeApps(fallback: .notRunning)

        #expect(await CompositeOwnerProvider(first: unsure, then: running).state(of: owner, for: item) == .running)
        #expect(await CompositeOwnerProvider(first: idle, then: running).state(of: owner, for: item) == .notRunning)
        #expect(await CompositeOwnerProvider(first: running, then: idle).state(of: owner, for: item) == .running)
        #expect(await CompositeOwnerProvider(first: unsure, then: unsure).state(of: owner, for: item) == .unknown)
    }

    @Test func composite_secondIsNotAskedWhenTheFirstKnows() async {
        let second = RecordingApps(answer: .running)
        let composite = CompositeOwnerProvider(first: FakeApps(fallback: .notRunning), then: second)
        _ = await composite.state(of: .processName("tool"), for: URL(filePath: "/tmp/x"))
        #expect(second.owners.isEmpty)
    }
}
