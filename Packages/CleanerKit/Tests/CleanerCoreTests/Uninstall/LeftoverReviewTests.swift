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

    // MARK: Brief 9.4: contents measured after matching (`LeftoverMatcher.reviewed`)

    private static func candidate(
        tier: Tier = .safe, evidence: LeftoverEvidence = .exactBundleID("com.example.Foo"), scope: LeftoverScope = .user
    ) -> LeftoverCandidate {
        LeftoverCandidate(
            place: LeftoverPlace(scope: scope, folder: .containers), name: "com.example.Foo", tier: tier,
            evidence: evidence)
    }

    private static let gigabyte = LeftoverMatcher.largeFolderBytes

    @Test(arguments: [
        (LeftoverContents(allocatedBytes: LeftoverMatcher.largeFolderBytes + 1, hasDocuments: false), Tier.review, "It is larger than 1 GB."),
        (LeftoverContents(allocatedBytes: 10, hasDocuments: true), .review, "Contains documents."),
        (
            LeftoverContents(allocatedBytes: 10, hasDocuments: false, hasDiskImages: true), .review,
            "Contains virtual machines or disk images."
        ),
        // A disk image wins over documents and size.
        (
            LeftoverContents(allocatedBytes: LeftoverMatcher.largeFolderBytes * 5, hasDocuments: true, hasDiskImages: true), .review,
            "Contains virtual machines or disk images."
        ),
        (LeftoverContents(allocatedBytes: LeftoverMatcher.largeFolderBytes, hasDocuments: false, hasDiskImages: nil), .safe, ""),
        (LeftoverContents(allocatedBytes: 4_096, hasDocuments: false, hasDiskImages: false), .safe, ""),
        (LeftoverContents(), .safe, ""),
    ] as [(LeftoverContents, Tier, String)])
    func reviewedAppliesTheContents(contents: LeftoverContents, tier: Tier, text: String) {
        let result = LeftoverMatcher.reviewed(Self.candidate(), contents: contents)
        #expect(result.tier == tier)
        if tier == .safe {
            #expect(result == Self.candidate())
        } else {
            #expect(result.evidence.text == "\(LeftoverEvidence.exactBundleID("com.example.Foo").text) \(text)")
        }
    }

    @Test func reviewedNeverPromotesAReviewOrInfoCandidate() {
        let calm = LeftoverContents(allocatedBytes: 1, hasDocuments: false, hasDiskImages: false)
        for tier in [Tier.review, .info] {
            let input = Self.candidate(tier: tier)
            #expect(LeftoverMatcher.reviewed(input, contents: calm) == input)
            #expect(LeftoverMatcher.reviewed(input, contents: calm, isComplete: false) == input)
        }
    }

    @Test func reviewedDoesNotWrapAWarningTwice() {
        let warned = Self.candidate(
            tier: .safe, evidence: .withWarning(.virtualMachinesOrDiskImages, .exactBundleID("com.example.Foo")))
        let contents = LeftoverContents(allocatedBytes: Self.gigabyte * 2, hasDocuments: true, hasDiskImages: true)
        #expect(LeftoverMatcher.reviewed(warned, contents: contents) == warned)

        let once = LeftoverMatcher.reviewed(Self.candidate(), contents: contents)
        #expect(LeftoverMatcher.reviewed(once, contents: contents) == once)
        if case .withWarning(_, let base) = once.evidence {
            if case .withWarning = base { Issue.record("wrapped twice") }
        } else {
            Issue.record("no warning")
        }
    }

    @Test func reviewedLeavesSystemLibraryCandidatesAlone() {
        let contents = LeftoverContents(allocatedBytes: Self.gigabyte * 2, hasDocuments: true, hasDiskImages: true)
        let input = Self.candidate(tier: .safe, scope: .system)
        #expect(LeftoverMatcher.reviewed(input, contents: contents) == input)
    }

    @Test func aPartialMeasurementIsReviewButOnlyWhenNothingElseWarns() {
        let calm = LeftoverContents(allocatedBytes: 1, hasDocuments: false, hasDiskImages: nil)
        let partial = LeftoverMatcher.reviewed(Self.candidate(), contents: calm, isComplete: false)
        #expect(partial.tier == .review)
        #expect(partial.evidence.text.hasSuffix("What is inside could not be read."))

        let docs = LeftoverContents(allocatedBytes: 1, hasDocuments: true, hasDiskImages: nil)
        let both = LeftoverMatcher.reviewed(Self.candidate(), contents: docs, isComplete: false)
        #expect(both.evidence.text.hasSuffix("Contains documents."))
    }

    @Test func reviewedAndMatchGiveTheSameAnswerForTheSameContents() {
        let contents = LeftoverContents(allocatedBytes: Self.gigabyte + 1, hasDocuments: false, hasDiskImages: false)
        let viaMatch = Fixtures.match(Fixtures.app(), Self.container(contents)).candidates.first
        let plain = Fixtures.match(Fixtures.app(), Self.container()).candidates.first
        #expect(plain?.tier == .safe)
        #expect(plain.map { LeftoverMatcher.reviewed($0, contents: contents) } == viaMatch)
    }
}
