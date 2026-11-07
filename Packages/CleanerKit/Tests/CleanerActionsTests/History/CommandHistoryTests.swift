import CleanerCore
import CleanerTestSupport
import Foundation
import Testing

@testable import CleanerActions

/// `command` lines in `history.jsonl` and the runner calls that write them (`REQ-CLEAN-03`, `REQ-CLEAN-07`).
/// Every command here is a fake script in a fixture folder; no real tool runs.
struct CommandHistoryTests {
    private typealias Support = OwnerTestSupport

    private static let udid = "0F3A9C2E-5B7D-4E1A-9C6F-1D2B3A4C5D6E"

    private func result(
        _ id: OwnerCommandID = .brewCleanup, exitCode: Int32? = 0, timedOut: Bool = false,
        skipped: String? = nil, tail: String = "ok\n"
    ) -> OwnerCommandResult {
        OwnerCommandResult(
            id: id, executable: skipped == nil ? "/fixture/bin/tool" : nil, exitCode: exitCode, timedOut: timedOut,
            skipped: skipped, outputTail: tail, duration: .milliseconds(1500))
    }

    private func itemReport(_ name: String, outcome: ItemOutcome) -> ItemReport {
        ItemReport(
            findingID: UUID(), ruleID: "test.rule", originalPath: URL(filePath: "/fixture/\(name)"), fsid: 1,
            fileID: 2, estimatedBytes: 4096, privateBytes: 1024, outcome: outcome)
    }

    // MARK: HistoryStore

    @Test func commands_roundTripEveryFieldOfARunTimeoutAndSkip() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let store = HistoryStore(fileURL: tree.url(for: "history.jsonl"))
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        try await store.recordCommand(
            result(.brewCleanup, exitCode: 3, tail: "boom\n"), ruleID: "dev.homebrew", startedAt: base)
        try await store.recordCommand(
            result(.goCleanCache, exitCode: nil, timedOut: true), ruleID: "dev.go", startedAt: base.addingTimeInterval(10))
        try await store.recordCommand(
            result(.pnpmStorePrune, exitCode: nil, skipped: "tool not found", tail: ""),
            ruleID: "dev.pnpm", startedAt: base.addingTimeInterval(20))

        let records = try await store.commands()
        #expect(records.map(\.ruleID) == ["dev.pnpm", "dev.go", "dev.homebrew"])
        #expect(records.map(\.startedAt) == [base.addingTimeInterval(20), base.addingTimeInterval(10), base])
        let skipped = try #require(records.first)
        #expect(skipped.result.id == .pnpmStorePrune)
        #expect(skipped.result.skipped == "tool not found")
        #expect(skipped.result.exitCode == nil)
        #expect(skipped.result.executable == nil)
        let timedOut = records[1]
        #expect(timedOut.result.timedOut)
        #expect(timedOut.result.exitCode == nil)
        let failed = records[2]
        #expect(failed.result.exitCode == 3)
        #expect(failed.result.outputTail == "boom\n")
        #expect(failed.result.executable == "/fixture/bin/tool")
        #expect(failed.result.duration == .milliseconds(1500))
        #expect(Set(records.map(\.id)).count == 3)
    }

    @Test func commands_areWrittenAsOneLineOfTypeCommand() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let file = tree.url(for: "history.jsonl")
        let store = HistoryStore(fileURL: file)
        try await store.recordCommand(result(tail: "line one\nline two\n"), ruleID: "dev.homebrew")

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 1)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(object["type"] as? String == "command")
    }

    @Test func commands_withoutStartTimeUseTheTimeTheRunTookCountedBackFromNow() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let store = HistoryStore(fileURL: tree.url(for: "history.jsonl"))
        let slow = OwnerCommandResult(
            id: .brewCleanup, executable: nil, exitCode: 0, timedOut: false, skipped: nil, outputTail: "",
            duration: .seconds(100))
        let before = Date()
        try await store.recordCommand(slow, ruleID: "dev.homebrew")
        let record = try #require(try await store.commands().first)
        // Dates are stored in whole seconds, so allow a second either way.
        let offset = record.startedAt.timeIntervalSince(before)
        #expect(offset < -98.9 && offset > -101.1)
    }

    @Test func commands_ofRunsInTheSameSecondKeepTheLaterLineFirst() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let store = HistoryStore(fileURL: tree.url(for: "history.jsonl"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.recordCommand(result(.dockerImagePrune), ruleID: "dev.dockerDangling", startedAt: start)
        try await store.recordCommand(result(.dockerBuilderPrune), ruleID: "dev.dockerDangling", startedAt: start)

        #expect(try await store.commands().map(\.result.id) == [.dockerBuilderPrune, .dockerImagePrune])
    }

    @Test func commands_ofAFileWithoutCommandLinesIsEmptyAndCleansStillRead() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let store = HistoryStore(fileURL: tree.url(for: "history.jsonl"))
        let id = UUID()
        try await store.begin(CleanPlan(items: []), id: id)
        try await store.record(itemReport("a", outcome: .deleted), cleanID: id)

        #expect(try await store.commands().isEmpty)
        #expect(try await store.cleans().map(\.id) == [id])
    }

    @Test func commands_missingFileIsAnEmptyList() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let store = HistoryStore(fileURL: tree.url(for: "nothing/history.jsonl"))
        #expect(try await store.commands().isEmpty)
    }

    @Test func commands_doNotChangeWhatCleansItemsFollowUpsAndTrashedItemsReport() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let store = HistoryStore(fileURL: tree.url(for: "history.jsonl"))
        let id = UUID()
        let moved = itemReport("a", outcome: .moved(to: URL(filePath: "/fixture/.Trash/a")))
        try await store.begin(CleanPlan(items: []), id: id)
        try await store.recordCommand(result(), ruleID: "dev.homebrew")
        try await store.record(moved, cleanID: id)
        try await store.recordCommand(result(.goCleanCache), ruleID: "dev.go")

        #expect(try await store.cleans().count == 1)
        #expect(try await store.items(of: id).map(\.findingID) == [moved.findingID])
        #expect(try await store.followUps().isEmpty)
        #expect(try await store.trashedItems().map(\.item.findingID) == [moved.findingID])
        #expect(try await store.commands().count == 2)
    }

    @Test func commands_aTruncatedLastLineIsSkippedAndTheNextRecordIsNotGluedToIt() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let file = tree.url(for: "history.jsonl")
        let store = HistoryStore(fileURL: file)
        try await store.recordCommand(result(.brewCleanup), ruleID: "dev.homebrew")

        // A crash in the middle of writing the next command line.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"command","cleanID":"#.utf8))
        try handle.close()

        #expect(try await store.commands().map(\.ruleID) == ["dev.homebrew"])

        try await store.recordCommand(result(.goCleanCache), ruleID: "dev.go")
        #expect(Set(try await store.commands().map(\.ruleID)) == ["dev.homebrew", "dev.go"])
    }

    // MARK: OwnerCommandRunner

    @Test func run_recordsARunWithItsRuleExitCodeAndOutput() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "go", exitCode: 2, stdout: "out", stderr: "err")
        let runner = Support.runner([Support.definition(.goCleanCache, candidates: [tool.path], arguments: ["clean"])])
        let store = HistoryStore(fileURL: tree.url(for: "state/history.jsonl"))

        let result = await runner.run(.goCleanCache, ruleID: "dev.go", history: store)

        #expect(result.exitCode == 2)
        let record = try #require(try await store.commands().first)
        #expect(record.ruleID == "dev.go")
        #expect(record.result.id == .goCleanCache)
        #expect(record.result.exitCode == 2)
        #expect(record.result.outputTail == "out\nerr\n")
        #expect(record.result.executable == tool.path)
        #expect(tool.records().count == 1)
    }

    @Test func run_recordsASkippedCommandWithItsReason() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let missing = tree.url(for: "bin/go").path
        let runner = Support.runner([Support.definition(.goCleanCache, candidates: [missing], arguments: ["clean"])])
        let store = HistoryStore(fileURL: tree.url(for: "history.jsonl"))

        let result = await runner.run(.goCleanCache, ruleID: "dev.go", history: store)

        #expect(result.skipped == "tool not found")
        let record = try #require(try await store.commands().first)
        #expect(record.result.skipped == "tool not found")
        #expect(record.result.exitCode == nil)
    }

    @Test func run_recordsACommandThatIsNotOnTheAllowList() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let runner = Support.runner([])
        let store = HistoryStore(fileURL: tree.url(for: "history.jsonl"))

        let result = await runner.run(OwnerCommandID(rawValue: "rm.everything"), ruleID: "x", history: store)

        #expect(result.skipped == "not an allowed command")
        #expect(try await store.commands().first?.result.skipped == "not an allowed command")
    }

    @Test func run_recordsTheTimeTheRunBegan() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "go")
        let runner = Support.runner([Support.definition(.goCleanCache, candidates: [tool.path], arguments: ["clean"])])
        let store = HistoryStore(fileURL: tree.url(for: "history.jsonl"))

        let before = Date()
        _ = await runner.run(.goCleanCache, ruleID: "dev.go", history: store)
        let after = Date()

        // Dates are stored in whole seconds, so the stored time may be up to a second early.
        let record = try #require(try await store.commands().first)
        #expect(record.startedAt >= before.addingTimeInterval(-1))
        #expect(record.startedAt <= after)
    }

    @Test func run_withoutHistoryRunsAndWritesNothing() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "go")
        let runner = Support.runner([Support.definition(.goCleanCache, candidates: [tool.path], arguments: ["clean"])])

        let result = await runner.run(.goCleanCache, ruleID: "dev.go", history: nil)

        #expect(result.succeeded)
        #expect(tool.records().count == 1)
        #expect(!FileManager.default.fileExists(atPath: tree.url(for: "history.jsonl").path))
    }

    @Test func run_aHistoryThatCannotBeWrittenStillReturnsTheTrueResult() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "go", exitCode: 4)
        let runner = Support.runner([Support.definition(.goCleanCache, candidates: [tool.path], arguments: ["clean"])])
        // "blocker" is a file, so the history folder below it cannot be created.
        _ = try tree.addFile("blocker")
        let store = HistoryStore(fileURL: tree.url(for: "blocker/history.jsonl"))

        let result = await runner.run(.goCleanCache, ruleID: "dev.go", history: store)

        #expect(result.exitCode == 4)
        #expect(result.skipped == nil)
        #expect(tool.records().count == 1)
    }

    @Test func deleteSimulator_recordsTheRunUnderItsRule() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "xcrun")
        let runner = Support.runner([], xcrun: [tool.path], devices: .success([Support.device(Self.udid)]))
        let store = HistoryStore(fileURL: tree.url(for: "history.jsonl"))

        let result = await runner.deleteSimulator(udid: Self.udid, ruleID: "dev.simDevices", history: store)

        #expect(result.succeeded)
        let record = try #require(try await store.commands().first)
        #expect(record.ruleID == "dev.simDevices")
        #expect(record.result.id == .simctlDeleteDevice)
        #expect(record.result.exitCode == 0)
    }

    @Test func deleteSimulator_recordsARefusalWhenTheDeviceIsRunning() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "xcrun")
        let runner = Support.runner(
            [], xcrun: [tool.path], devices: .success([Support.device(Self.udid, state: "Booted")]))
        let store = HistoryStore(fileURL: tree.url(for: "history.jsonl"))

        _ = await runner.deleteSimulator(udid: Self.udid, ruleID: "dev.simDevices", history: store)

        let record = try #require(try await store.commands().first)
        #expect(record.result.skipped == "the simulator is not shut down")
        #expect(tool.records().isEmpty)
    }

    @Test func deleteSimulatorRuntime_recordsTheRunUnderItsRule() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let identifier = "7C1F2A3B-4D5E-6F70-8192-A3B4C5D6E7F8"
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "xcrun")
        let runner = Support.runner([], xcrun: [tool.path], runtimes: .success([Support.runtime(identifier)]))
        let store = HistoryStore(fileURL: tree.url(for: "history.jsonl"))

        let result = await runner.deleteSimulatorRuntime(
            identifier: identifier, ruleID: "dev.simRuntimes", history: store)

        #expect(result.succeeded)
        let record = try #require(try await store.commands().first)
        #expect(record.ruleID == "dev.simRuntimes")
        #expect(record.result.id == .simctlDeleteRuntime)
    }

    @Test func deleteSimulatorRuntime_recordsABadIdentifierAsSkipped() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let runner = Support.runner([])
        let store = HistoryStore(fileURL: tree.url(for: "history.jsonl"))

        _ = await runner.deleteSimulatorRuntime(identifier: "--all", ruleID: "dev.simRuntimes", history: store)

        let record = try #require(try await store.commands().first)
        #expect(record.result.skipped == "not a valid runtime identifier")
    }
}
