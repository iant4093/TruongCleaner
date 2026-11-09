import CleanerTestSupport
import Foundation
import Testing
import os

@testable import CleanerActions

struct UpdateDownloaderTests {
    private let zipBytes = Data("pretend this is a zip".utf8)

    private func downloader(
        _ tree: FixtureTree, archive: Data, checksums: String, delay: Duration = .zero,
        timeLimit: Duration = .seconds(30)
    ) -> (UpdateDownloader, FakeFetcher) {
        let fetcher = FakeFetcher(archive: archive, checksums: Data(checksums.utf8), delay: delay)
        let downloader = UpdateDownloader(
            fetcher: fetcher, workRoot: tree.url(for: "tmp"), timeLimit: timeLimit)
        return (downloader, fetcher)
    }

    private func prepareTmp(_ tree: FixtureTree) throws {
        try tree.addDirectory("tmp")
    }

    // MARK: Checksum

    @Test func download_acceptsAMatchingChecksum() async throws {
        try await withUpdateTree { tree in
            try prepareTmp(tree)
            let (downloader, fetcher) = downloader(
                tree, archive: zipBytes, checksums: FixtureAssets.checksumLine(for: zipBytes))
            let progress = FractionLog()
            let result = try await downloader.download(FixtureAssets.make()) { progress.add($0) }

            #expect(try Data(contentsOf: result.archive) == zipBytes)
            #expect(result.folder.lastPathComponent.hasPrefix(UpdateWorkspace.folderPrefix))
            #expect(result.archive.deletingLastPathComponent() == result.folder)
            #expect(Set(fetcher.requestedURLs) == [FixtureAssets.archiveURL, FixtureAssets.checksumsURL])
            let values = progress.values
            #expect(values.last == 1)
            #expect(values.allSatisfy { (0...1).contains($0) })
        }
    }

    @Test func download_refusesAChecksumMismatchAndLeavesNothingBehind() async throws {
        try await withUpdateTree { tree in
            try prepareTmp(tree)
            let wrong = FixtureAssets.checksumLine(for: Data("different bytes".utf8))
            let (downloader, _) = downloader(tree, archive: zipBytes, checksums: wrong)

            await #expect(throws: UpdateError.checksumMismatch) {
                try await downloader.download(FixtureAssets.make()) { _ in }
            }
            #expect(updateFolders(in: tree.url(for: "tmp")).isEmpty)
        }
    }

    @Test(arguments: [
        "",
        "not a checksum file\n",
        "\(String(repeating: "a", count: 64))  Other.zip\n",
        "\(String(repeating: "a", count: 63))  TruongCleaner.zip\n",
        "\(String(repeating: "g", count: 64))  TruongCleaner.zip\n",
        // Two lines for the same file: ambiguous, so refused.
        "\(String(repeating: "a", count: 64))  TruongCleaner.zip\n\(String(repeating: "b", count: 64))  TruongCleaner.zip\n",
    ])
    func download_refusesAnUnusableChecksumFile(_ checksums: String) async throws {
        try await withUpdateTree { tree in
            try prepareTmp(tree)
            let (downloader, _) = downloader(tree, archive: zipBytes, checksums: checksums)

            await #expect(throws: UpdateError.checksumMissing) {
                try await downloader.download(FixtureAssets.make()) { _ in }
            }
            #expect(updateFolders(in: tree.url(for: "tmp")).isEmpty)
        }
    }

    @Test func checksums_readTheShasumFormat() {
        let digest = String(repeating: "ab", count: 32)
        #expect(UpdateChecksums.expectedDigest(for: "TruongCleaner.zip", in: "\(digest)  TruongCleaner.zip\n") == digest)
        // Binary-mode marker and upper case.
        #expect(
            UpdateChecksums.expectedDigest(for: "TruongCleaner.zip", in: "\(digest.uppercased()) *TruongCleaner.zip\n") == digest)
        // A longer name is a different file.
        #expect(UpdateChecksums.expectedDigest(for: "TruongCleaner.zip", in: "\(digest)  TruongCleaner.zip.sig\n") == nil)
        // The ZIP's line among others.
        let other = String(repeating: "cd", count: 32)
        #expect(
            UpdateChecksums.expectedDigest(
                for: "TruongCleaner.zip", in: "\(other)  TruongCleaner.dmg\n\(digest)  TruongCleaner.zip\n") == digest)
    }

    // MARK: Limits

    @Test func download_stopsAfterTheTimeLimit() async throws {
        try await withUpdateTree { tree in
            try prepareTmp(tree)
            let (downloader, _) = downloader(
                tree, archive: zipBytes, checksums: FixtureAssets.checksumLine(for: zipBytes),
                delay: .seconds(30), timeLimit: .milliseconds(200))

            await #expect(throws: UpdateError.timedOut) {
                try await downloader.download(FixtureAssets.make()) { _ in }
            }
            #expect(updateFolders(in: tree.url(for: "tmp")).isEmpty)
        }
    }

    @Test func download_stopsWhenCancelled() async throws {
        try await withUpdateTree { tree in
            try prepareTmp(tree)
            let (downloader, _) = downloader(
                tree, archive: zipBytes, checksums: FixtureAssets.checksumLine(for: zipBytes), delay: .seconds(30))
            let assets = try FixtureAssets.make()
            let task = Task { try await downloader.download(assets) { _ in } }
            try await Task.sleep(for: .milliseconds(100))
            task.cancel()

            await #expect(throws: UpdateError.cancelled) { try await task.value }
            #expect(updateFolders(in: tree.url(for: "tmp")).isEmpty)
        }
    }

    // MARK: Address allow-list

    @Test(arguments: [
        "https://github.com/iant4093/TruongCleaner/releases/download/build-21/TruongCleaner.zip",
        "https://GitHub.com/iant4093/TruongCleaner/releases/download/build-21/SHA256SUMS",
    ])
    func urlPolicy_allowsReleaseAssets(_ text: String) throws {
        let url = try #require(URL(string: text))
        #expect(UpdateURLPolicy.isAllowedAssetURL(url))
        #expect(UpdateURLPolicy.isAllowedRedirect(url))
    }

    @Test(arguments: [
        "http://github.com/iant4093/TruongCleaner/releases/download/build-21/TruongCleaner.zip",
        "https://evil.example/iant4093/TruongCleaner/releases/download/build-21/TruongCleaner.zip",
        "https://github.com.evil.example/iant4093/TruongCleaner/releases/download/build-21/TruongCleaner.zip",
        "https://github.com@evil.example/iant4093/TruongCleaner/releases/download/build-21/TruongCleaner.zip",
        "https://user:pw@github.com/iant4093/TruongCleaner/releases/download/build-21/TruongCleaner.zip",
        "https://github.com:8443/iant4093/TruongCleaner/releases/download/build-21/TruongCleaner.zip",
        "https://github.com/someone-else/TruongCleaner/releases/download/build-21/TruongCleaner.zip",
        "https://github.com/iant4093/TruongCleaner/releases/latest/download/TruongCleaner.zip",
        "https://github.com/iant4093/TruongCleaner/releases/download/",
        "https://github.com/iant4093/TruongCleaner/releases/download/../../../../evil/x.zip",
        "https://objects.githubusercontent.com/github-production-release-asset/1/TruongCleaner.zip",
        "file:///tmp/TruongCleaner.zip",
        "ftp://github.com/iant4093/TruongCleaner/releases/download/build-21/TruongCleaner.zip",
    ])
    func urlPolicy_refusesEverythingElseAsAnAssetAddress(_ text: String) throws {
        let url = try #require(URL(string: text))
        #expect(!UpdateURLPolicy.isAllowedAssetURL(url))
        #expect(UpdateAssets(archive: url, checksums: FixtureAssets.checksumsURL) == nil)
        #expect(UpdateAssets(archive: FixtureAssets.archiveURL, checksums: url) == nil)
    }

    @Test(arguments: [
        "https://objects.githubusercontent.com/github-production-release-asset/1/TruongCleaner.zip",
        "https://release-assets.githubusercontent.com/github-production-release-asset/1/TruongCleaner.zip",
    ])
    func urlPolicy_allowsGitHubAssetHostsOnRedirectOnly(_ text: String) throws {
        let url = try #require(URL(string: text))
        #expect(UpdateURLPolicy.isAllowedRedirect(url))
        #expect(!UpdateURLPolicy.isAllowedAssetURL(url))
    }

    @Test(arguments: [
        "http://objects.githubusercontent.com/x",
        "https://githubusercontent.com/x",
        "https://evil.objects.githubusercontent.com/x",
        "https://objects.githubusercontent.com.evil.example/x",
        "https://objects.githubusercontent.com:8443/x",
        "https://evil.example/x",
        "https://github.com/iant4093/other-repo/releases/download/x/y",
    ])
    func urlPolicy_refusesOtherRedirectTargets(_ text: String) throws {
        let url = try #require(URL(string: text))
        #expect(!UpdateURLPolicy.isAllowedRedirect(url))
    }
}

/// Collects progress values from a `@Sendable` callback.
private final class FractionLog: Sendable {
    private let lock = OSAllocatedUnfairLock<[Double]>(initialState: [])
    func add(_ value: Double) { lock.withLock { $0.append(value) } }
    var values: [Double] { lock.withLock { $0 } }
}
