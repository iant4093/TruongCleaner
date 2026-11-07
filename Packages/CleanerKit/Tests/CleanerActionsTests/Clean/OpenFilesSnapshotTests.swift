import CleanerCore
import CleanerTestSupport
import Darwin
import Foundation
import Testing

@testable import CleanerActions

/// Opens a file read-only with close-on-exec, so a child process started by a parallel test
/// cannot inherit the descriptor and keep the file open after we close it.
private func openReadOnly(_ url: URL) throws -> Int32 {
    let descriptor = open(url.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return descriptor
}

struct OpenFilesSnapshotTests {
    @Test func snapshot_seesAHandleThisProcessHoldsAndForgetsItInTheNextSnapshot() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let file = try tree.addFile("held/held.bin", size: 10)
        let sibling = try tree.addFile("held/held.bin.other", size: 10)
        let folder = file.deletingLastPathComponent()

        let descriptor = try openReadOnly(file)
        let whileOpen = await OpenFilesSnapshot.take(excludingPIDs: [])
        #expect(await whileOpen.hasOpenFiles(under: file) == true)
        // The folder that contains the open file counts as in use.
        #expect(await whileOpen.hasOpenFiles(under: folder) == true)
        // A name that merely starts the same is a different item.
        #expect(await whileOpen.hasOpenFiles(under: sibling) == false)
        close(descriptor)

        // The old snapshot keeps its answer; a new one sees the file closed.
        #expect(await whileOpen.hasOpenFiles(under: file) == true)
        let afterClose = await OpenFilesSnapshot.take(excludingPIDs: [])
        #expect(await afterClose.hasOpenFiles(under: file) == false)
        #expect(await afterClose.hasOpenFiles(under: folder) == false)
    }

    @Test func snapshot_ignoresThisProcessByDefault() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let file = try tree.addFile("held.bin", size: 10)
        let descriptor = try openReadOnly(file)
        defer { close(descriptor) }

        let snapshot = await OpenFilesSnapshot.take()
        #expect(await snapshot.hasOpenFiles(under: file) == false)
    }

    @Test func snapshot_recognisesAFileHeldUnderAnotherName() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let original = try tree.addFile("one/original.bin", size: 10)
        let link = try tree.addHardLink("two/link.bin", to: original)

        let descriptor = try openReadOnly(original)
        defer { close(descriptor) }
        let snapshot = await OpenFilesSnapshot.take(excludingPIDs: [])
        #expect(await snapshot.hasOpenFiles(under: link) == true)
    }

    @Test func snapshot_comparesNamesWithoutRegardToCase() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let file = try tree.addFile("Mixed/Case.bin", size: 1)
        let snapshot = OpenFilesSnapshot(
            heldPaths: [PathParts.components(of: file)?.map { $0.uppercased() } ?? []],
            identities: [], completeness: .complete)
        #expect(await snapshot.hasOpenFiles(under: file) == true)
    }

    @Test func snapshot_failedSnapshotNeverSaysNothingIsOpen() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let file = try tree.addFile("a.bin", size: 1)
        #expect(await OpenFilesSnapshot.failed.hasOpenFiles(under: file) == nil)
    }

    @Test func snapshot_incompleteSnapshotStillReportsHitsButNeverAFalseAllClear() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let held = try tree.addFile("held.bin", size: 1)
        let other = try tree.addFile("other.bin", size: 1)
        let snapshot = OpenFilesSnapshot(
            heldPaths: [try #require(PathParts.components(of: held))], identities: [], completeness: .incomplete)
        #expect(await snapshot.hasOpenFiles(under: held) == true)
        #expect(await snapshot.hasOpenFiles(under: other) == nil)
    }

    @Test func snapshot_unreadableItemIsUnknown() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let snapshot = OpenFilesSnapshot(heldPaths: [], identities: [], completeness: .complete)
        #expect(await snapshot.hasOpenFiles(under: tree.root.appending(path: "missing.bin")) == nil)
    }

    @Test func snapshot_answersFromMemoryMuchFasterThanTheProviderScan() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let file = try tree.addFile("a.bin", size: 1)
        let snapshot = await OpenFilesSnapshot.take(excludingPIDs: [])
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            for _ in 0..<200 { _ = await snapshot.hasOpenFiles(under: file) }
        }
        // 200 questions to the old provider would take about 24 s. Allow a generous 2 s.
        #expect(elapsed < .seconds(2))
    }

    // MARK: ProcessInspector self-checks

    @Test func inspector_aSnapshotThatReachedTooFewProcessesIsUnknown() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let file = try tree.addFile("a.bin", size: 1)
        // Process 1 (launchd) belongs to root: an ordinary user cannot read it, so nothing was seen.
        let snapshot = ProcessInspector.capture(excluding: [], listProcesses: { [1] })
        #expect(await snapshot.hasOpenFiles(under: file) == nil)
    }

    @Test func inspector_noProcessListIsUnknown() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let file = try tree.addFile("a.bin", size: 1)
        #expect(await ProcessInspector.capture(excluding: [], listProcesses: { nil }).hasOpenFiles(under: file) == nil)
        #expect(await ProcessInspector.capture(excluding: [], listProcesses: { [] }).hasOpenFiles(under: file) == nil)
    }

    @Test func inspector_readableProcessesGiveADefiniteAnswer() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let file = try tree.addFile("a.bin", size: 1)
        let me = getpid()
        let snapshot = ProcessInspector.capture(excluding: [], listProcesses: { [me] })
        #expect(await snapshot.hasOpenFiles(under: file) == false)
        let descriptor = try openReadOnly(file)
        defer { close(descriptor) }
        #expect(await ProcessInspector.capture(excluding: [], listProcesses: { [me] }).hasOpenFiles(under: file) == true)
    }

    @Test func inspector_aFolderQueryAndAFileQueryComeFromTheSameSnapshot() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let file = try tree.addFile("logs/deep/held.log", size: 1)
        let descriptor = try openReadOnly(file)
        defer { close(descriptor) }
        let snapshot = await OpenFilesSnapshot.take(excludingPIDs: [])
        // One snapshot answers for the file and every folder above it alike.
        for url in [file, tree.url(for: "logs/deep"), tree.url(for: "logs")] {
            #expect(await snapshot.hasOpenFiles(under: url) == true)
        }
    }
}
