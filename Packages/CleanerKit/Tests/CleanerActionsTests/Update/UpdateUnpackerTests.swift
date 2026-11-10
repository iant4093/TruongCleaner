import CleanerTestSupport
import Foundation
import Testing

@testable import CleanerActions

struct UpdateUnpackerTests {
    /// A download folder holding `TruongCleaner.zip` and `SHA256SUMS`, as the downloader leaves it.
    private func downloadFolder(_ tree: FixtureTree, zipping contents: String) throws -> DownloadedUpdate {
        let folder = try UpdateWorkspace.makeFolder(in: tree.url(for: "tmp"))
        let archive = folder.appending(path: "TruongCleaner.zip")
        try FixtureApp.zip(contentsOf: tree.url(for: contents), to: archive)
        try Data().write(to: folder.appending(path: "SHA256SUMS"))
        try Data().write(to: folder.appending(path: "SHA256SUMS.sig"))
        return DownloadedUpdate(folder: folder, archive: archive)
    }

    @Test func unpack_returnsTheSingleApp() async throws {
        try await withUpdateTree { tree in
            try tree.addDirectory("tmp")
            try FixtureApp.make(in: tree, at: "payload/TruongCleaner.app")
            let download = try downloadFolder(tree, zipping: "payload")

            let app = try await UpdateUnpacker().unpack(download)

            #expect(app.lastPathComponent == "TruongCleaner.app")
            #expect(app.deletingLastPathComponent().lastPathComponent == "extract")
            #expect(FixtureApp.build(of: app) == 2000)
            // The signature survives the round trip.
            _ = try await UpdateVerifier().verify(app, against: .fixture)
        }
    }

    @Test func unpack_refusesAnArchiveWithAnExtraTopLevelItem() async throws {
        try await withUpdateTree { tree in
            try tree.addDirectory("tmp")
            try FixtureApp.make(in: tree, at: "payload/TruongCleaner.app")
            try tree.addFile("payload/readme.txt", size: 4)
            let download = try downloadFolder(tree, zipping: "payload")

            await #expect(throws: UpdateError.unexpectedArchiveContents) {
                try await UpdateUnpacker().unpack(download)
            }
        }
    }

    @Test func unpack_refusesAnUnknownFileNextToTheDownload() async throws {
        try await withUpdateTree { tree in
            try tree.addDirectory("tmp")
            try FixtureApp.make(in: tree, at: "payload/TruongCleaner.app")
            let download = try downloadFolder(tree, zipping: "payload")
            try Data("x".utf8).write(to: download.folder.appending(path: "notes.txt"))

            await #expect(throws: UpdateError.unexpectedArchiveContents) {
                try await UpdateUnpacker().unpack(download)
            }
        }
    }

    @Test func unpack_refusesADownloadFolderWithoutTheSignatureFile() async throws {
        try await withUpdateTree { tree in
            try tree.addDirectory("tmp")
            try FixtureApp.make(in: tree, at: "payload/TruongCleaner.app")
            let download = try downloadFolder(tree, zipping: "payload")
            try FileManager.default.removeItem(at: download.folder.appending(path: "SHA256SUMS.sig"))

            await #expect(throws: UpdateError.unexpectedArchiveContents) {
                try await UpdateUnpacker().unpack(download)
            }
        }
    }

    @Test func unpack_refusesAnArchiveWithAnotherAppName() async throws {
        try await withUpdateTree { tree in
            try tree.addDirectory("tmp")
            try FixtureApp.make(in: tree, at: "payload/Other.app")
            let download = try downloadFolder(tree, zipping: "payload")

            await #expect(throws: UpdateError.unexpectedArchiveContents) {
                try await UpdateUnpacker().unpack(download)
            }
        }
    }

    @Test func unpack_refusesAnArchiveWhereTheAppIsAFile() async throws {
        try await withUpdateTree { tree in
            try tree.addDirectory("tmp")
            try tree.addFile("payload/TruongCleaner.app", size: 4)
            let download = try downloadFolder(tree, zipping: "payload")

            await #expect(throws: UpdateError.unexpectedArchiveContents) {
                try await UpdateUnpacker().unpack(download)
            }
        }
    }

    @Test func unpack_reportsACorruptArchive() async throws {
        try await withUpdateTree { tree in
            try tree.addDirectory("tmp")
            let folder = try UpdateWorkspace.makeFolder(in: tree.url(for: "tmp"))
            let archive = folder.appending(path: "TruongCleaner.zip")
            try Data("this is not a zip file".utf8).write(to: archive)
            try Data().write(to: folder.appending(path: "SHA256SUMS"))
            try Data().write(to: folder.appending(path: "SHA256SUMS.sig"))

            let error = try await #require(throws: UpdateError.self) {
                try await UpdateUnpacker().unpack(DownloadedUpdate(folder: folder, archive: archive))
            }
            guard case .unpackFailed = error else {
                Issue.record("Expected unpackFailed, got \(error)")
                return
            }
        }
    }

    @Test func unpack_failsWhenDittoIsMissing() async throws {
        try await withUpdateTree { tree in
            try tree.addDirectory("tmp")
            try FixtureApp.make(in: tree, at: "payload/TruongCleaner.app")
            let download = try downloadFolder(tree, zipping: "payload")
            let unpacker = UpdateUnpacker(dittoPath: tree.url(for: "no-such-ditto").path(percentEncoded: false), timeout: .seconds(5))

            await #expect(throws: UpdateError.unpackFailed("ditto is missing")) {
                try await unpacker.unpack(download)
            }
        }
    }
}
