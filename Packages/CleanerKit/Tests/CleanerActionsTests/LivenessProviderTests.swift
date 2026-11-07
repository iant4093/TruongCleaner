import CleanerCore
import CleanerTestSupport
import Darwin
import Foundation
import Testing

@testable import CleanerActions

/// Runs a child process for the length of a test and ends it afterwards.
private final class Child {
    let process = Process()

    init(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil) throws {
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
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
        #expect(await provider.hasOpenFiles(under: file) == false)
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
        #expect(await ProcessOpenFilesProvider().hasOpenFiles(under: file) == false)
    }

    @Test func openFiles_anotherProcessHoldingAFileIsSeenForTheFileAndItsFolders() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let file = try tree.addFile("logs/deep/held.log", size: 10)
        let child = try Child("/usr/bin/tail", ["-f", file.path(percentEncoded: false)])
        defer { child.stop() }
        let provider = ProcessOpenFilesProvider()

        #expect(await eventually { await provider.hasOpenFiles(under: file) == true })
        // A file inside the folder is open, so the folder counts, at every level.
        #expect(await provider.hasOpenFiles(under: tree.url(for: "logs/deep")) == true)
        #expect(await provider.hasOpenFiles(under: tree.url(for: "logs")) == true)
        // An unrelated sibling does not.
        let other = try tree.addFile("other/idle.bin", size: 10)
        #expect(await provider.hasOpenFiles(under: other) == false)
        #expect(await provider.hasOpenFiles(under: tree.url(for: "other")) == false)

        child.stop()
        #expect(await eventually { await provider.hasOpenFiles(under: file) == false })
    }

    @Test func openFiles_processWhoseCurrentFolderIsInsideTheItemCounts() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let inner = try tree.addDirectory("project/build")
        let child = try Child("/bin/sleep", ["30"], currentDirectory: inner)
        defer { child.stop() }
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
        defer { child.stop() }
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
        child.stop()
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
        #expect(await provider.state(of: .childNameAsBundleID, for: root.appending(path: "plain/x")) == .notRunning)
        #expect(await provider.state(of: .childNameAsBundleID, for: root.appending(path: "a.b/x")) == .notRunning)
        #expect(await provider.state(of: .childNameAsBundleID, for: root.appending(path: "com.example.Tool/x")) == .unknown)
        #expect(await provider.state(of: .childNameAsBundleID, for: URL(filePath: "/elsewhere/com.a.b")) == .unknown)
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
