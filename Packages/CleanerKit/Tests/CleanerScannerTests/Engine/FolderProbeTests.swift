import CleanerTestSupport
import Darwin
import Foundation
import Testing
@testable import CleanerScanner

/// Scanner review #12: the error code comes from the call that failed. (APFS refuses names that are not
/// UTF-8, so the non-UTF-8 `realpath` case of the fix cannot be built as a fixture.)
struct FolderProbeTests {
    @Test func aMissingFolderIsMissingAndAFileIsNotAFolder() throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("file.txt", size: 1)
        let missing = tree.root.appending(path: "nope", directoryHint: .isDirectory)

        guard case .failure(let code) = FolderProbe.kind(of: missing) else {
            Issue.record("a missing folder was found")
            return
        }
        #expect(code == ENOENT)
        guard case .other = FolderProbe.kind(of: tree.url(for: "file.txt")) else {
            Issue.record("a file was taken for a folder")
            return
        }
        guard case .failure(.missing) = FolderProbe.realPath(of: missing) else {
            Issue.record("a missing path did not map to .missing")
            return
        }
    }

    @Test func aFileUsedAsAFolderReportsNotADirectory() throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("file.txt", size: 1)

        guard case .failure(let code) = FolderProbe.kind(of: tree.url(for: "file.txt").appending(path: "child")) else {
            Issue.record("a path below a file was found")
            return
        }
        #expect(code == ENOTDIR)
    }

    @Test func aClosedFolderReportsAccessDeniedNotMissing() throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("closed/inner/x", size: 1)
        try tree.setPermissions("closed", mode: 0o000)
        // Running as root would open it anyway.
        guard geteuid() != 0 else { return }

        guard case .failure(let code) = FolderProbe.kind(of: tree.url(for: "closed/inner")) else {
            Issue.record("a folder inside a closed folder was found")
            return
        }
        #expect(code == EACCES)
        guard case .failure(.denied) = FolderProbe.childFolders(of: tree.url(for: "closed")) else {
            Issue.record("listing a closed folder did not map to .denied")
            return
        }
    }
}
