import CleanerTestSupport
import Darwin
import Foundation
import Testing
@testable import CleanerScanner

/// Category measurement on a fixture home. Nothing here reads the real home folder or `/Applications`.
struct CategoryScannerTests {
    /// APFS allocates in 4 KB units, so sizes that are multiples of this have exact expected values.
    private static let page = 4096

    private func bytes(_ pages: Int) -> Int64 { Int64(pages * Self.page) }

    /// A fixture machine: `Applications`, `Users/me` (the home), `Users/other` and `Users/Shared`.
    /// Every file has a different page count, so a misplaced file shows up as a wrong total.
    private struct Machine {
        let tree: FixtureTree
        var home: URL { tree.url(for: "Users/me") }
        var applications: URL { tree.url(for: "Applications") }
        var users: URL { tree.url(for: "Users") }

        init() throws { tree = try FixtureTree() }

        func file(_ path: String, pages: Int) throws {
            try tree.addFile(path, size: pages * CategoryScannerTests.page)
        }

        func fill() throws {
            try file("Applications/Some.app/Contents/exe", pages: 1)
            try file("Users/me/Applications/Mine.app/exe", pages: 2)
            try file("Users/me/Documents/Work/report.txt", pages: 3)
            try file("Users/me/Downloads/big.zip", pages: 4)
            try file("Users/me/Desktop/shot.png", pages: 5)
            try file("Users/me/Pictures/Photos Library.photoslibrary/o", pages: 6)
            try file("Users/me/Movies/film.mov", pages: 7)
            try file("Users/me/Music/song.m4a", pages: 8)
            try file("Users/me/Library/Mobile Documents/com~apple~CloudDocs/doc", pages: 9)
            try file("Users/me/Library/Caches/com.example/cache", pages: 10)
            try file("Users/me/Library/Developer/Xcode/DerivedData/d", pages: 11)
            try file("Users/me/Library/Application Support/MobileSync/Backup/UDID/b", pages: 12)
            try file("Users/me/Library/Application Support/Other/o", pages: 13)
            try file("Users/me/Library/Mail/V10/m", pages: 14)
            try file("Users/me/Library/Containers/com.apple.mail/Data/m2", pages: 15)
            try file("Users/me/Library/Messages/Attachments/a", pages: 16)
            try file("Users/me/Library/Containers/com.example/Data/z", pages: 17)
            try file("Users/me/Library/loose.plist", pages: 18)
            try file("Users/me/.Trash/t", pages: 19)
            try file("Users/me/Projects/code/x", pages: 20)
            try file("Users/me/note.txt", pages: 21)
            try file("Users/other/o", pages: 22)
            try file("Users/Shared/s", pages: 23)
        }

        func measure() async -> CategoryTotals {
            await CategoryScanner.measure(home: home, applicationsRoot: applications, usersRoot: users)
        }
    }

    @Test
    func everyCategoryGetsItsOwnBytes() async throws {
        let machine = try Machine()
        defer { machine.tree.remove() }
        try machine.fill()

        let totals = await machine.measure()

        let expected: [StorageCategory: Int] = [
            .applications: 1 + 2,
            .documents: 3,
            .downloads: 4,
            .desktop: 5,
            .pictures: 6,
            .movies: 7,
            .music: 8,
            .icloud: 9,
            .libraryCaches: 10,
            .developer: 11,
            .iosBackups: 12,
            .libraryOther: 13 + 17 + 18,
            .mail: 14 + 15,
            .messages: 16,
            .trash: 19,
            .otherHome: 20 + 21,
            .otherUsers: 22 + 23,
        ]
        for category in StorageCategory.allCases {
            #expect(totals.bytes(of: category) == bytes(expected[category] ?? 0), "\(category)")
        }
        #expect(expected.count == StorageCategory.allCases.count)
        #expect(!totals.partial)
        #expect(totals.totalNeedsAccess == 0)
        // No clones here, so deleting a category frees what it occupies.
        #expect(totals.privateBytes == totals.bytes)
    }

    @Test
    func nestedRootsAreNotCountedTwice() async throws {
        let machine = try Machine()
        defer { machine.tree.remove() }
        try machine.fill()

        let totals = await machine.measure()

        // The categories of the home folder add up to exactly what one plain walk of the home finds.
        let walk = try await BulkWalker.walk(machine.home, options: WalkOptions(totalsDepth: 0))
        let homeCategories = StorageCategory.allCases.filter { $0 != .applications && $0 != .otherUsers }
        let sum = homeCategories.reduce(Int64(0)) { $0 + totals.bytes(of: $1) }
        // `Applications` inside the home belongs to the applications category.
        let homeApplications = bytes(2)
        #expect(sum + homeApplications == walk.nodes.first?.allocatedBytes)
        // The carved-out Library folders are not in "libraryOther" as well.
        #expect(totals.bytes(of: .libraryOther) == bytes(13 + 17 + 18))
    }

    @Test
    func theHomeFolderIsNotAlsoAnotherUser() async throws {
        let machine = try Machine()
        defer { machine.tree.remove() }
        try machine.fill()

        let totals = await machine.measure()

        #expect(totals.bytes(of: .otherUsers) == bytes(22 + 23))
    }

    @Test
    func symlinksAreNotFollowed() async throws {
        let machine = try Machine()
        defer { machine.tree.remove() }
        try machine.fill()
        let before = await machine.measure()

        let outside = machine.tree.url(for: "Users/other")
        try machine.tree.addSymlink("Users/me/Documents/link", destination: outside)
        try machine.tree.addSymlink("Users/me/linked-folder", destination: outside)
        try machine.tree.addSymlink("Users/me/Library/Caches/link", destination: outside)
        let after = await machine.measure()

        #expect(after.bytes == before.bytes)
    }

    @Test
    func aDeniedFolderInsideACategoryIsCountedAsNeedsAccess() async throws {
        try #require(getuid() != 0, "Permissions do not stop root")
        let machine = try Machine()
        defer { machine.tree.remove() }
        try machine.fill()
        try machine.file("Users/me/Documents/Locked/hidden", pages: 30)
        try machine.tree.setPermissions("Users/me/Documents/Locked", mode: 0o000)

        let totals = await machine.measure()

        #expect(totals.needsAccess[.documents] == 1)
        // The locked folder's bytes are unknown, not part of the total.
        #expect(totals.bytes(of: .documents) == bytes(3))
        #expect(totals.totalNeedsAccess == 1)
    }

    @Test
    func aDeniedCategoryRootIsNeedsAccessAndNotSilentlyZero() async throws {
        try #require(getuid() != 0, "Permissions do not stop root")
        let machine = try Machine()
        defer { machine.tree.remove() }
        try machine.fill()
        try machine.tree.setPermissions("Users/me/Desktop", mode: 0o000)
        try machine.tree.setPermissions("Users/other", mode: 0o000)

        let totals = await machine.measure()

        #expect(totals.needsAccess[.desktop] == 1)
        #expect(totals.bytes(of: .desktop) == 0)
        #expect(totals.needsAccess[.otherUsers] == 1)
        // The readable sibling is still counted.
        #expect(totals.bytes(of: .otherUsers) == bytes(23))
        #expect(totals.bytes(of: .documents) == bytes(3))
    }

    @Test
    func aDeniedFolderInsideLibraryGoesToItsCategory() async throws {
        try #require(getuid() != 0, "Permissions do not stop root")
        let machine = try Machine()
        defer { machine.tree.remove() }
        try machine.fill()
        try machine.tree.setPermissions("Users/me/Library/Messages", mode: 0o000)
        try machine.tree.setPermissions("Users/me/Library/Application Support/Other", mode: 0o000)

        let totals = await machine.measure()

        #expect(totals.needsAccess[.messages] == 1)
        #expect(totals.bytes(of: .messages) == 0)
        #expect(totals.needsAccess[.libraryOther] == 1)
        #expect(totals.bytes(of: .libraryOther) == bytes(17 + 18))
        // The other Library categories are unaffected.
        #expect(totals.bytes(of: .mail) == bytes(14 + 15))
        #expect(totals.bytes(of: .iosBackups) == bytes(12))
    }

    @Test
    func childrenThatCannotBeExaminedAreNeedsAccessNotPartial() async throws {
        try #require(getuid() != 0, "Permissions do not stop root")
        let tree = try FixtureTree()
        defer { tree.remove() }
        let home = try tree.addDirectory("home")
        try tree.addFile("home/Documents/d", size: Self.page)
        try tree.addFile("home/note.txt", size: Self.page)
        // Readable but not searchable: the names list, but each child's size cannot be read.
        try tree.setPermissions("home", mode: 0o444)

        let totals = await CategoryScanner.measure(home: home, applicationsRoot: nil, usersRoot: nil)

        #expect(totals.needsAccess[.documents] == 1)
        #expect(totals.needsAccess[.otherHome] == 1)
        #expect(totals.totalBytes == 0)
        #expect(!totals.partial)
    }

    @Test
    func aCancelledMeasurementIsPartial() async throws {
        let machine = try Machine()
        defer { machine.tree.remove() }
        try machine.fill()
        let home = machine.home
        let applications = machine.applications
        let users = machine.users

        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return await CategoryScanner.measure(home: home, applicationsRoot: applications, usersRoot: users)
        }
        task.cancel()
        let totals = await task.value

        #expect(totals.partial)
    }

    @Test
    func missingRootsMeasureAsEmpty() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let home = try tree.addDirectory("home")

        let totals = await CategoryScanner.measure(home: home, applicationsRoot: nil, usersRoot: nil)

        #expect(totals.totalBytes == 0)
        #expect(!totals.partial)
        #expect(totals.totalNeedsAccess == 0)
        for category in StorageCategory.allCases {
            #expect(totals.bytes[category] == 0)
        }
    }

    @Test
    func aMissingHomeIsEmptyNotAnError() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }

        let totals = await CategoryScanner.measure(
            home: tree.url(for: "no-such-home"), applicationsRoot: nil, usersRoot: nil)

        #expect(totals.totalBytes == 0)
        #expect(!totals.partial)
    }

    @Test(arguments: [
        (["Caches"], StorageCategory.libraryCaches),
        (["Caches", "com.example", "deep"], .libraryCaches),
        (["Developer", "Xcode"], .developer),
        (["Mobile Documents"], .icloud),
        (["Containers", "com.apple.mail", "Data"], .mail),
        (["Containers", "com.example"], .libraryOther),
        (["Application Support", "MobileSync", "Backup", "UDID"], .iosBackups),
        (["Application Support", "MobileSync"], .libraryOther),
        (["Preferences"], .libraryOther),
        ([], .libraryOther),
    ])
    func libraryPathsMapToTheLongestCarveOut(path: [String], expected: StorageCategory) {
        #expect(CategoryPlan.libraryCategory(forRelative: path) == expected)
    }

    @Test
    func theLibraryWalkKeepsTotalsDeepEnoughForEveryCarveOut() {
        let deepest = CategoryPlan.libraryCarveOuts.keys.map { $0.split(separator: "/").count }.max()
        #expect(CategoryPlan.libraryTotalsDepth == deepest)
        // No carve-out is inside another, so subtracting them cannot remove a byte twice.
        let paths = Array(CategoryPlan.libraryCarveOuts.keys)
        for first in paths {
            for second in paths where first != second {
                #expect(!second.hasPrefix(first + "/"), "\(second) is inside \(first)")
            }
        }
    }
}
