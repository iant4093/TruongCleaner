import Foundation
import Testing

@testable import CleanerCore

/// Review fixes 9 and 15: a folder that may hold data nobody can rebuild is offered but not selected.
struct LeftoverReviewTests {
    private typealias Fixtures = UninstallFixtures

    private static func container(_ contents: LeftoverContents? = nil) -> [LeftoverPlace: [LeftoverEntry]] {
        [Fixtures.user(.containers): [LeftoverEntry(name: "com.example.Foo", contents: contents)]]
    }

    @Test(arguments: [
        "Docker.raw", "docker.RAW", "Windows 11.utm", "Ubuntu.pvm", "Fedora.vmwarevm", "data.img",
        "Backup.sparsebundle", "installer.dmg",
    ])
    func folderWithAVirtualMachineOrDiskImageIsReview(name: String) {
        let matches = Fixtures.match(Fixtures.app(), Self.container(), children: { _, _ in ["Data", name] })
        #expect(matches.candidates.count == 1)
        #expect(matches.candidates.first?.tier == .review)
        #expect(matches.candidates.first?.evidence.text.contains("Contains virtual machines or disk images") == true)
    }

    @Test func measuredDiskImageDeepInsideIsReview() {
        let contents = LeftoverContents(allocatedBytes: 10, hasDocuments: false, hasDiskImages: true)
        let matches = Fixtures.match(Fixtures.app(), Self.container(contents))
        #expect(matches.candidates.first?.tier == .review)
        #expect(matches.candidates.first?.evidence.text.contains("Contains virtual machines or disk images") == true)
    }

    @Test func folderWithDocumentsIsReview() {
        let contents = LeftoverContents(allocatedBytes: 10, hasDocuments: true, hasDiskImages: false)
        let matches = Fixtures.match(Fixtures.app(), Self.container(contents))
        #expect(matches.candidates.first?.tier == .review)
        #expect(matches.candidates.first?.evidence.text.contains("Contains documents") == true)
    }

    @Test func folderLargerThanOneGigabyteIsReviewButExactlyOneGigabyteIsNot() {
        let big = LeftoverContents(allocatedBytes: LeftoverMatcher.largeFolderBytes + 1, hasDocuments: false, hasDiskImages: false)
        #expect(Fixtures.match(Fixtures.app(), Self.container(big)).candidates.first?.tier == .review)
        let edge = LeftoverContents(allocatedBytes: LeftoverMatcher.largeFolderBytes, hasDocuments: false, hasDiskImages: false)
        #expect(Fixtures.match(Fixtures.app(), Self.container(edge)).candidates.first?.tier == .safe)
    }

    @Test func smallEmptyFolderStaysSafe() {
        let contents = LeftoverContents(allocatedBytes: 4_096, hasDocuments: false, hasDiskImages: false)
        let matches = Fixtures.match(Fixtures.app(), Self.container(contents))
        #expect(matches.candidates.first?.tier == .safe)
        #expect(matches.candidates.first?.evidence == .exactBundleID("com.example.Foo"))
    }

    @Test(arguments: [LeftoverFolder.applicationSupport, .caches, .containers])
    func theCheckAppliesToBundleIDFoldersInEveryUserPlace(folder: LeftoverFolder) {
        let contents = LeftoverContents(allocatedBytes: 1, hasDocuments: true, hasDiskImages: false)
        let matches = Fixtures.match(
            Fixtures.app(), [Fixtures.user(folder): [LeftoverEntry(name: "com.example.Foo", contents: contents)]])
        #expect(matches.candidates.first?.tier == .review)
    }

    @Test func aFileIsNotJudgedByItsContents() {
        let contents = LeftoverContents(allocatedBytes: 1, hasDocuments: true, hasDiskImages: true)
        let matches = Fixtures.match(
            Fixtures.app(),
            [Fixtures.user(.preferences): [LeftoverEntry(name: "com.example.Foo.plist", isDirectory: false, contents: contents)]])
        #expect(matches.candidates.first?.tier == .safe)
    }

    @Test func systemLibraryItemsStayInfo() {
        let matches = Fixtures.match(
            Fixtures.app(),
            [Fixtures.system(.applicationSupport): [LeftoverEntry(name: "com.example.Foo")]],
            children: { _, _ in ["Docker.raw"] })
        #expect(matches.candidates.first?.tier == .info)
    }

    @Test(arguments: [
        ("Docker.raw", nil, true), ("data.img", nil, true), ("A.UTM", nil, true), ("A.pvm", nil, true),
        ("A.vmwarevm", nil, true), ("A.sparsebundle", nil, true), ("A.dmg", nil, true),
        ("A.dmg", Int64(2_000_000_000), true), ("A.dmg", Int64(1_000_000_000), false),
        ("notes.txt", nil, false), ("Docker.raw.bak", nil, false), ("img", nil, false),
    ] as [(String, Int64?, Bool)])
    func diskImageNames(name: String, bytes: Int64?, expected: Bool) {
        #expect(LeftoverMatcher.isVirtualMachineOrDiskImage(name: name, allocatedBytes: bytes) == expected)
    }

    // MARK: Finding 15

    @Test func folderThatCannotBeListedIsReviewNotSafe() {
        let matches = Fixtures.match(
            Fixtures.app(), [Fixtures.user(.applicationSupport): [LeftoverEntry(name: "com.example.Foo")]],
            children: { _, _ in nil })
        #expect(matches.candidates.count == 1)
        #expect(matches.candidates.first?.tier == .review)
        #expect(matches.candidates.first?.evidence.text.contains("could not be read") == true)
    }

    @Test func folderThatCanBeListedStaysSafe() {
        let matches = Fixtures.match(
            Fixtures.app(), [Fixtures.user(.applicationSupport): [LeftoverEntry(name: "com.example.Foo")]],
            children: { _, _ in ["data"] })
        #expect(matches.candidates.first?.tier == .safe)
    }

    @Test func warningKeepsTheOriginalEvidenceText() {
        let evidence = LeftoverEvidence.withWarning(.documents, .exactBundleID("com.example.Foo"))
        #expect(evidence.text.hasPrefix(LeftoverEvidence.exactBundleID("com.example.Foo").text))
    }
}
