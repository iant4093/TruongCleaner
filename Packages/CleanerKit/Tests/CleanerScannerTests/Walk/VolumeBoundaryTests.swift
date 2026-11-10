import CleanerTestSupport
import Darwin
import Foundation
import Testing
@testable import CleanerScanner

/// The walker must stay on the volume it started on (REQ-SCAN-03), must not open mount points, and must
/// say whether its totals are complete. Tree-based tests use fixtures under `build/test-fixtures/`; the
/// two tests that look at the startup disk only read folder metadata of `/` and `/System/Volumes`.
struct VolumeBoundaryTests {
    private static let page = 4096

    // MARK: Scanner review #1: System and Data share ATTR_CMN_FSID

    @Test func theSystemAndDataVolumesHaveDifferentVolumeIdentities() throws {
        let system = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        let data = open("/System/Volumes/Data", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer {
            if system >= 0 { close(system) }
            if data >= 0 { close(data) }
        }
        // A Mac without the split (or a runner that hides it) has nothing to compare.
        guard system >= 0, data >= 0 else { return }
        let systemVolume = try #require(volumeIdentity(of: system))
        let dataVolume = try #require(volumeIdentity(of: data))
        #expect(systemVolume != dataVolume)
    }

    @Test func aWalkOfTheVolumesFolderNeverEntersData() async throws {
        guard FileManager.default.fileExists(atPath: "/System/Volumes/Data") else { return }
        let volumes = URL(filePath: "/System/Volumes", directoryHint: .isDirectory)
        // `Data` is listed with the same ATTR_CMN_FSID as its parent, so only the mount status and the
        // volume identity keep the walk out. Walking it would take far longer than the limit.
        let result = try await BulkWalker.walk(
            volumes, options: WalkOptions(maxWorkers: 2, totalsDepth: 1, limit: .seconds(10)))

        #expect(result.partial == false)
        #expect(result.crossVolumeSkipped >= 1)
        #expect(!result.nodes.contains { $0.url.lastPathComponent == "Data" })
    }

    // MARK: Scanner review #2: mount points are skipped before they are opened

    @Test func aVolumeMountedInsideTheTreeIsSkippedAndNotCounted() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        // The image file itself lies in the tree's root, so the walk starts one level down.
        try tree.addFile("data/a.bin", size: Self.page * 2)
        try tree.addFile("data/docs/b.bin", size: Self.page)

        try await MountedImage.with(tree, at: "data/mnt") { _ in
            try tree.addFile("data/mnt/inside.bin", size: Self.page * 10)
            try tree.addFile("data/mnt/deep/more.bin", size: Self.page * 5)

            let result = try await BulkWalker.walk(
                tree.url(for: "data"), options: WalkOptions(maxWorkers: 2, totalsDepth: 2))

            #expect(result.crossVolumeSkipped == 1)
            #expect(result.files == 2)
            #expect(result.directories == 2)  // the root and docs; the mount point is not entered
            #expect(result.nodes.first?.allocatedBytes == Int64(Self.page * 3))
            #expect(!result.nodes.contains { $0.url.lastPathComponent == "mnt" })
            #expect(result.otherErrors == 0)
            #expect(result.partial == false)
        }
    }

    // MARK: Scanner review #11: a volume mounted in the home folder is not Data-volume space

    @Test func categoryScanSkipsAVolumeMountedInTheHomeFolder() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("home/Documents/report.txt", size: Self.page * 3)
        try tree.addFile("home/note.txt", size: Self.page)

        try await MountedImage.with(tree, at: "home/Mounted") { _ in
            try tree.addFile("home/Mounted/big.bin", size: Self.page * 40)

            let totals = await CategoryScanner.measure(
                home: tree.url(for: "home"), applicationsRoot: nil, usersRoot: nil)

            #expect(totals.bytes(of: .documents) == Int64(Self.page * 3))
            #expect(totals.bytes(of: .otherHome) == Int64(Self.page))
            #expect(totals.totalBytes == Int64(Self.page * 4))
            #expect(!totals.partial)
        }
    }

    @Test func categoryScanSkipsAVolumeMountedUnderTheUsersFolder() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("Users/me/note.txt", size: Self.page)
        try tree.addFile("Users/other/o.bin", size: Self.page * 2)

        try await MountedImage.with(tree, at: "Users/Mounted") { _ in
            try tree.addFile("Users/Mounted/big.bin", size: Self.page * 40)

            let totals = await CategoryScanner.measure(
                home: tree.url(for: "Users/me"), applicationsRoot: nil, usersRoot: tree.url(for: "Users"))

            #expect(totals.bytes(of: .otherUsers) == Int64(Self.page * 2))
            #expect(totals.totalBytes == Int64(Self.page * 3))
        }
    }

    // MARK: Scanner review #4: dropped entries make a result incomplete

    private func result(partial: Bool = false, otherErrors: Int = 0) -> WalkResult {
        WalkResult(
            root: URL(filePath: "/x", directoryHint: .isDirectory), volume: 1, nodes: [], topFiles: [], files: 0,
            directories: 1, symlinks: 0, hardLinkDuplicates: 0, crossVolumeSkipped: 0, deniedDirectories: [],
            deniedCount: 0, otherErrors: otherErrors, privateSizeMissing: 0, partial: partial)
    }

    @Test func aWalkWithNonPermissionErrorsIsIncomplete() {
        #expect(result().isIncomplete == false)
        #expect(result(partial: true).isIncomplete)
        #expect(result(otherErrors: 1).isIncomplete)
    }

    // MARK: Scanner review #6: file or folder for an entry that came back with an error

    /// Builds one packed `getattrlistbulk` entry for a failed item: length, five attribute words,
    /// error, name reference, then the fsid and object type when `withType` is set, then the name.
    private func failedEntry(name: String, errorCode: Int32, type: UInt32?, withFSID: Bool) -> [UInt8] {
        var common = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_ERROR) | UInt32(ATTR_CMN_NAME)
        if withFSID { common |= UInt32(ATTR_CMN_FSID) }
        if type != nil { common |= UInt32(ATTR_CMN_OBJTYPE) }
        var words: [UInt32] = [0, common, 0, 0, 0, 0]  // length placeholder, then the returned set
        words.append(UInt32(bitPattern: errorCode))
        let nameField = words.count
        words.append(0)  // name offset, set below
        words.append(UInt32(name.utf8.count + 1))
        if withFSID { words += [1, 2] }
        if let type { words.append(type) }
        let nameOffset = (words.count - nameField) * 4
        words[nameField] = UInt32(nameOffset)
        var bytes = words.flatMap { word in withUnsafeBytes(of: word) { Array($0) } }
        bytes += Array(name.utf8) + [0]
        while bytes.count % 4 != 0 { bytes.append(0) }
        bytes.replaceSubrange(0..<4, with: withUnsafeBytes(of: UInt32(bytes.count)) { Array($0) })
        return bytes
    }

    private func readFailed(_ bytes: [UInt8]) throws -> (code: Int32, name: String, isDirectory: Bool) {
        let read = bytes.withUnsafeBytes { raw -> (code: Int32, name: String, isDirectory: Bool)? in
            guard let base = raw.baseAddress else { return nil }
            var reader = EntryReader(base: base, length: raw.count, offset: 4)
            guard let common = reader.take(UInt32.self) else { return nil }
            for _ in 0..<4 { _ = reader.take(UInt32.self) }
            guard let failed = FailedEntry.read(&reader, common: common, entry: base, length: raw.count) else {
                return nil
            }
            return (failed.code, String(cString: failed.name), failed.isDirectory)
        }
        return try #require(read)
    }

    @Test func aDeniedFileIsNotReportedAsAFolder() throws {
        let entry = failedEntry(name: "secret.db", errorCode: EPERM, type: 1, withFSID: true)  // VREG
        let read = try readFailed(entry)
        #expect(read.code == EPERM)
        #expect(read.name == "secret.db")
        #expect(read.isDirectory == false)
    }

    @Test func aDeniedFolderIsReportedAsAFolder() throws {
        let entry = failedEntry(name: "Private", errorCode: EACCES, type: 2, withFSID: true)  // VDIR
        let read = try readFailed(entry)
        #expect(read.code == EACCES)
        #expect(read.isDirectory)
    }

    @Test func aDeniedEntryOfUnknownKindCountsAsAFile() throws {
        let entry = failedEntry(name: "mystery", errorCode: EPERM, type: nil, withFSID: false)
        #expect(try readFailed(entry).isDirectory == false)
    }
}
