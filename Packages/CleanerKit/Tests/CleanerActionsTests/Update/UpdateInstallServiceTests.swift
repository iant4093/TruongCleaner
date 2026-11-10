import CleanerTestSupport
import CryptoKit
import Foundation
import Testing
import os

@testable import CleanerActions

struct UpdateInstallServiceTests {
    /// Builds the release files for a new app with the given spec and returns a service wired to
    /// fixture folders, plus the running app.
    private struct Harness {
        let service: UpdateInstallService
        let running: URL
        let applications: URL
        let tmp: URL
    }

    private func harness(_ tree: FixtureTree, new spec: FixtureApp.Spec, tamperChecksum: Bool = false) throws -> Harness {
        try tree.addDirectory("Applications")
        try tree.addDirectory("tmp")
        var old = FixtureApp.Spec()
        old.build = 1000
        let running = try FixtureApp.make(in: tree, at: "Applications/TruongCleaner.app", old)

        try FixtureApp.make(in: tree, at: "release/TruongCleaner.app", spec)
        let zip = tree.url(for: "release.zip")
        try FixtureApp.zip(contentsOf: tree.url(for: "release"), to: zip)
        let zipBytes = try Data(contentsOf: zip)
        let line = FixtureAssets.checksumLine(for: tamperChecksum ? Data("other".utf8) : zipBytes)

        let signer = FixtureSigner()
        let sums = Data(line.utf8)
        let fetcher = FakeFetcher(archive: zipBytes, checksums: sums, signature: try signer.signatureFile(for: sums))
        let applications = tree.url(for: "Applications")
        let service = UpdateInstallService(
            downloader: UpdateDownloader(fetcher: fetcher, workRoot: tree.url(for: "tmp"), trust: signer.trust),
            installer: UpdateInstaller(allowedParents: [applications]))
        return Harness(service: service, running: running, applications: applications, tmp: tree.url(for: "tmp"))
    }

    @Test func prepareAndInstall_replacesTheRunningAppEndToEnd() async throws {
        try await withUpdateTree { tree in
            let harness = try harness(tree, new: FixtureApp.Spec())
            let stages = StageLog()

            let prepared = try await harness.service.prepare(
                FixtureAssets.make(), identity: .fixture) { stages.add($0) }
            #expect(prepared.verified.bundleVersion == 2000)
            #expect(stages.all.contains(.verifying))
            #expect(stages.all.contains(.downloading(1)))
            // Nothing is installed yet.
            #expect(FixtureApp.build(of: harness.running) == 1000)

            let aside = try await harness.service.install(prepared, replacing: harness.running)

            #expect(FixtureApp.build(of: harness.running) == 2000)
            #expect(FixtureApp.build(of: aside) == 1000)
            #expect(updateFolders(in: harness.tmp).isEmpty)
            // The next launch tidies the old bundle away.
            let executor = RecordingExecutor()
            let report = await UpdateCleanup(executor: executor).removeLeftovers(
                in: harness.applications, bundleIdentifier: FixtureApp.ourID, temporaryDirectory: harness.tmp)
            #expect(report.trashedBundles == [aside])
        }
    }

    @Test func prepare_installsNothingAndLeavesNothingWhenTheChecksumDoesNotMatch() async throws {
        try await withUpdateTree { tree in
            let harness = try harness(tree, new: FixtureApp.Spec(), tamperChecksum: true)

            await #expect(throws: UpdateError.checksumMismatch) {
                try await harness.service.prepare(FixtureAssets.make(), identity: .fixture) { _ in }
            }
            #expect(FixtureApp.build(of: harness.running) == 1000)
            #expect(updateFolders(in: harness.tmp).isEmpty)
        }
    }

    @Test func prepare_removesTheDownloadWhenVerificationFails() async throws {
        try await withUpdateTree { tree in
            var spec = FixtureApp.Spec()
            spec.build = 999
            let harness = try harness(tree, new: spec)

            await #expect(throws: UpdateError.notNewer) {
                try await harness.service.prepare(FixtureAssets.make(), identity: .fixture) { _ in }
            }
            #expect(FixtureApp.build(of: harness.running) == 1000)
            #expect(updateFolders(in: harness.tmp).isEmpty)
        }
    }

    @Test func install_keepsTheOldAppWhenTheSwapIsRefused() async throws {
        try await withUpdateTree { tree in
            let harness = try harness(tree, new: FixtureApp.Spec())
            let prepared = try await harness.service.prepare(FixtureAssets.make(), identity: .fixture) { _ in }
            try tree.setPermissions("Applications", mode: 0o555)

            await #expect(throws: UpdateError.notWritable) {
                try await harness.service.install(prepared, replacing: harness.running)
            }
            #expect(FixtureApp.build(of: harness.running) == 1000)
            #expect(updateFolders(in: harness.tmp).isEmpty)
        }
    }
}

private final class StageLog: Sendable {
    private let lock = OSAllocatedUnfairLock<[UpdateStage]>(initialState: [])
    func add(_ stage: UpdateStage) { lock.withLock { $0.append(stage) } }
    var all: [UpdateStage] { lock.withLock { $0 } }
}
