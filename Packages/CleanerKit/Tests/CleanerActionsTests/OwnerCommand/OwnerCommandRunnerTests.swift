import CleanerScanner
import CleanerTestSupport
import Foundation
import Testing

@testable import CleanerActions

struct OwnerCommandRunnerTests {
    private typealias Support = OwnerTestSupport

    // MARK: Argv and environment

    @Test(arguments: [
        ("brew", ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1"]),
        ("docker", ["DOCKER_CLI_HINTS": "false"]),
        ("go", [:]),
    ] as [(String, [String: String])])
    func exactArgvAndScrubbedEnvironmentReachTheProcess(name: String, extra: [String: String]) async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: name, stdout: "ok")
        let id = OwnerCommandID(rawValue: "test.\(name)")
        let runner = Support.runner([
            Support.definition(id, candidates: [tool.path], arguments: ["cleanup", "--prune=30", "a b"]),
        ])

        let result = await runner.run(id)

        #expect(result.skipped == nil)
        #expect(result.exitCode == 0)
        #expect(result.succeeded)
        #expect(!result.timedOut)
        #expect(result.executable == tool.path)
        #expect(result.outputTail == "ok\n")
        let records = tool.records()
        #expect(records.count == 1)
        #expect(records.first?.arguments == ["cleanup", "--prune=30", "a b"])
        var expected = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:" + tool.url.deletingLastPathComponent().path,
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
        ]
        expected.merge(extra) { _, new in new }
        #expect(records.first?.environment == expected)
    }

    @Test func nonZeroExitIsReportedAsRanButNotSucceeded() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "go", exitCode: 3, stderr: "boom")
        let runner = Support.runner([Support.definition(.goCleanCache, candidates: [tool.path], arguments: ["clean"])])

        let result = await runner.run(.goCleanCache)

        #expect(result.skipped == nil)
        #expect(result.exitCode == 3)
        #expect(!result.succeeded)
        #expect(result.outputTail == "boom\n")
    }

    @Test func outputOfBothStreamsIsKeptInOrder() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "go", stdout: "to-out", stderr: "to-err")
        let runner = Support.runner([Support.definition(.goCleanCache, candidates: [tool.path], arguments: ["clean"])])

        let result = await runner.run(.goCleanCache)

        #expect(result.outputTail == "to-out\nto-err\n")
    }

    // MARK: Executable checks

    @Test func aMissingToolIsSkippedAndNothingRuns() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let missing = tree.url(for: "bin/go").path
        let runner = Support.runner([Support.definition(.goCleanCache, candidates: [missing], arguments: ["clean"])])

        let result = await runner.run(.goCleanCache)

        #expect(result.skipped == "tool not found")
        #expect(result.executable == nil)
        #expect(result.exitCode == nil)
        #expect(!result.timedOut)
        #expect(result.outputTail.isEmpty)
    }

    @Test func theFirstExistingCandidateIsUsed() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let first = try FakeTool.make(in: tree, folder: "a", name: "go")
        let second = try FakeTool.make(in: tree, folder: "b", name: "go")
        let missing = tree.url(for: "nowhere/go").path
        let runner = Support.runner([
            Support.definition(.goCleanCache, candidates: [missing, first.path, second.path], arguments: ["clean"]),
        ])

        let result = await runner.run(.goCleanCache)

        #expect(result.executable == first.path)
        #expect(first.records().count == 1)
        #expect(second.records().isEmpty)
    }

    @Test func aWorldWritableToolIsRefusedAndNothingRuns() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "go", mode: 0o757)
        let fallback = try FakeTool.make(in: tree, folder: "other", name: "go")
        let runner = Support.runner([
            Support.definition(.goCleanCache, candidates: [tool.path, fallback.path], arguments: ["clean"]),
        ])

        let result = await runner.run(.goCleanCache)

        #expect(result.skipped?.contains("world-writable") == true)
        #expect(result.exitCode == nil)
        #expect(tool.records().isEmpty)
        // The first existing candidate decides; a later one is not tried.
        #expect(fallback.records().isEmpty)
    }

    @Test func aToolThatIsNotExecutableIsRefused() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "go", mode: 0o644)
        let runner = Support.runner([Support.definition(.goCleanCache, candidates: [tool.path], arguments: ["clean"])])

        let result = await runner.run(.goCleanCache)

        #expect(result.skipped?.contains("not executable") == true)
        #expect(tool.records().isEmpty)
    }

    @Test func aFolderIsNotAnExecutable() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let folder = try tree.addDirectory("bin/go").path
        let runner = Support.runner([Support.definition(.goCleanCache, candidates: [folder], arguments: ["clean"])])

        let result = await runner.run(.goCleanCache)

        #expect(result.skipped?.contains("not a regular file") == true)
    }

    @Test func aRelativePathIsRefused() async {
        let runner = Support.runner([Support.definition(.goCleanCache, candidates: ["go"], arguments: ["clean"])])

        let result = await runner.run(.goCleanCache)

        #expect(result.skipped?.contains("absolute") == true)
        #expect(result.exitCode == nil)
    }

    @Test func aSymlinkToAnExecutableRuns() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let target = try FakeTool.make(in: tree, folder: "real", name: "brew")
        let link = try tree.addSymlink("bin/brew", destination: target.url)
        let runner = Support.runner([Support.definition(.brewCleanup, candidates: [link.path], arguments: ["cleanup"])])

        let result = await runner.run(.brewCleanup)

        #expect(result.exitCode == 0)
        #expect(result.executable == link.path)
        let records = target.records()
        #expect(records.count == 1)
        // PATH gets the directory of the path we were given, not of the link target.
        #expect(records.first?.environment["PATH"]?.hasSuffix(":" + link.deletingLastPathComponent().path) == true)
    }

    @Test func aSymlinkToAWorldWritableToolIsRefused() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let target = try FakeTool.make(in: tree, folder: "real", name: "brew", mode: 0o777)
        let link = try tree.addSymlink("bin/brew", destination: target.url)
        let runner = Support.runner([Support.definition(.brewCleanup, candidates: [link.path], arguments: ["cleanup"])])

        let result = await runner.run(.brewCleanup)

        #expect(result.skipped?.contains("world-writable") == true)
        #expect(target.records().isEmpty)
    }

    @Test func aDanglingSymlinkCountsAsMissing() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let link = try tree.addSymlink("bin/brew", destination: tree.url(for: "gone/brew"))
        let runner = Support.runner([Support.definition(.brewCleanup, candidates: [link.path], arguments: ["cleanup"])])

        let result = await runner.run(.brewCleanup)

        #expect(result.skipped == "tool not found")
    }

    // MARK: Timeout and output

    @Test func aCommandThatRunsTooLongIsStoppedAndReportedAsTimedOut() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "go", sleeps: true)
        let runner = Support.runner([
            // The script must reach its first log line before the timeout; 400 ms was too tight when
            // the whole suite runs at once and the shell starts slowly.
            Support.definition(.goCleanCache, candidates: [tool.path], arguments: ["clean"], timeout: .milliseconds(1500)),
        ])

        let result = await runner.run(.goCleanCache)

        #expect(result.timedOut)
        #expect(result.skipped == nil)
        #expect(result.exitCode == nil)
        #expect(!result.succeeded)
        #expect(result.duration < timingBudget(.seconds(4)))
        #expect(tool.records().count == 1)
    }

    @Test func outputTailIsCappedAtFourKilobytes() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "go", stdout: "END", filler: 100_000)
        let runner = Support.runner([Support.definition(.goCleanCache, candidates: [tool.path], arguments: ["clean"])])

        let result = await runner.run(.goCleanCache)

        #expect(result.exitCode == 0)
        #expect(result.outputTail.utf8.count == 4096)
        #expect(result.outputTail.hasSuffix("aaaEND\n"))
        #expect(result.outputTail.allSatisfy { $0 == "a" || $0 == "E" || $0 == "N" || $0 == "D" || $0 == "\n" })
    }

    @Test func tailTextStartsOnACharacterBoundary() {
        // 2-byte characters: a cut at 4096 bytes from the end lands inside one when the total is odd.
        let text = "x" + String(repeating: "é", count: 3000)
        let tail = OwnerProcess.tailText(Data(text.utf8))
        #expect(tail.utf8.count <= 4096)
        #expect(!tail.contains("\u{FFFD}"))
        #expect(tail.allSatisfy { $0 == "é" })
        #expect(OwnerProcess.tailText(Data("short\n".utf8)) == "short\n")
        #expect(OwnerProcess.tailText(Data()) == "")
    }

    // MARK: Preflight

    @Test func aRunningOwnerProcessBlocksTheCommand() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "brew")
        let runner = Support.runner(
            [Support.definition(.brewCleanup, candidates: [tool.path], arguments: ["cleanup"], preflight: .processNotRunning("brew"))],
            processRunning: true
        )

        let result = await runner.run(.brewCleanup)

        #expect(result.skipped == "brew is running")
        #expect(result.exitCode == nil)
        #expect(tool.records().isEmpty)
    }

    @Test func anUnknownProcessStateBlocksTheCommand() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "brew")
        let runner = Support.runner(
            [Support.definition(.brewCleanup, candidates: [tool.path], arguments: ["cleanup"], preflight: .processNotRunning("brew"))],
            processRunning: nil
        )

        let result = await runner.run(.brewCleanup)

        #expect(result.skipped?.contains("could not tell") == true)
        #expect(tool.records().isEmpty)
    }

    @Test func aProcessThatIsNotRunningLetsTheCommandRun() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "brew")
        let runner = Support.runner(
            [Support.definition(.brewCleanup, candidates: [tool.path], arguments: ["cleanup"], preflight: .processNotRunning("brew"))],
            processRunning: false
        )

        let result = await runner.run(.brewCleanup)

        #expect(result.exitCode == 0)
        #expect(tool.records().count == 1)
    }

    @Test func aBootedSimulatorBlocksDeleteUnavailable() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "xcrun")
        let definition = Support.definition(
            .simctlDeleteUnavailable, candidates: [tool.path],
            arguments: ["simctl", "delete", "unavailable"], preflight: .noBootedSimulator
        )
        let states = ["Booted", "Booting", "Shutting Down", "Unknown"]
        for state in states {
            let runner = Support.runner(
                [definition],
                devices: .success([Support.device("A", state: "Shutdown"), Support.device("B", state: state)])
            )
            let result = await runner.run(.simctlDeleteUnavailable)
            #expect(result.skipped == "a simulator is running", "\(state)")
        }
        #expect(tool.records().isEmpty)
    }

    @Test func anUnreadableSimulatorListBlocksDeleteUnavailable() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "xcrun")
        let runner = Support.runner(
            [Support.definition(
                .simctlDeleteUnavailable, candidates: [tool.path],
                arguments: ["simctl", "delete", "unavailable"], preflight: .noBootedSimulator
            )],
            devices: .failure(.timedOut)
        )

        let result = await runner.run(.simctlDeleteUnavailable)

        #expect(result.skipped?.contains("could not check simulators") == true)
        #expect(tool.records().isEmpty)
    }

    @Test func shutDownSimulatorsLetDeleteUnavailableRun() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "xcrun")
        let runner = Support.runner(
            [Support.definition(
                .simctlDeleteUnavailable, candidates: [tool.path],
                arguments: ["simctl", "delete", "unavailable"], preflight: .noBootedSimulator
            )],
            devices: .success([Support.device("A"), Support.device("B")])
        )

        let result = await runner.run(.simctlDeleteUnavailable)

        #expect(result.exitCode == 0)
        #expect(tool.records().map(\.arguments) == [["simctl", "delete", "unavailable"]])
    }

    @Test func dockerThatIsNotReachableIsSkippedAndOnlyTheCheckRuns() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "docker", infoExitCode: 1)
        let runner = Support.runner([
            Support.definition(.dockerImagePrune, candidates: [tool.path], arguments: ["image", "prune", "-f"], preflight: .dockerReachable),
        ])

        let result = await runner.run(.dockerImagePrune)

        #expect(result.skipped == "Docker is not running")
        #expect(result.exitCode == nil)
        let records = tool.records()
        #expect(records.map(\.arguments) == [["info", "--format", "{{.ServerVersion}}"]])
        // The check gets the same scrubbed environment as the command.
        #expect(records.first?.environment["DOCKER_CLI_HINTS"] == "false")
        #expect(records.first?.environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin:" + tool.url.deletingLastPathComponent().path)
    }

    @Test func dockerThatAnswersLetsThePruneRunAfterTheCheck() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "docker", infoExitCode: 0)
        let runner = Support.runner([
            Support.definition(.dockerImagePrune, candidates: [tool.path], arguments: ["image", "prune", "-f"], preflight: .dockerReachable),
        ])

        let result = await runner.run(.dockerImagePrune)

        #expect(result.exitCode == 0)
        #expect(tool.records().map(\.arguments) == [
            ["info", "--format", "{{.ServerVersion}}"],
            ["image", "prune", "-f"],
        ])
    }

    @Test func aRefusedToolFailsBeforeAnyPreflightRuns() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "docker", mode: 0o777)
        let runner = Support.runner([
            Support.definition(.dockerImagePrune, candidates: [tool.path], arguments: ["image", "prune", "-f"], preflight: .dockerReachable),
        ])

        let result = await runner.run(.dockerImagePrune)

        #expect(result.skipped?.contains("world-writable") == true)
        #expect(tool.records().isEmpty)
    }
}
