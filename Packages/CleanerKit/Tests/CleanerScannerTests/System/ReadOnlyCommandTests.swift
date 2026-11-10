import CleanerTestSupport
import Foundation
import Testing
@testable import CleanerScanner

struct ReadOnlyCommandTests {
    // MARK: Allow-list

    @Test func allowListHoldsOnlyTheListVerbs() {
        let expected: [String: [[String]]] = [
            "/usr/bin/tmutil": [["listlocalsnapshots", "/"], ["listlocalsnapshotdates", "/"]],
            "/usr/sbin/diskutil": [["apfs", "list", "-plist"], ["info", "-plist", "/"]],
            "/usr/bin/xcrun": [["simctl", "list", "devices", "--json"], ["simctl", "runtime", "list", "--json"]],
        ]
        #expect(ReadOnlyCommand.allowList == expected)
        #expect(ReadOnlyCommand.allowList.keys.allSatisfy { $0.hasPrefix("/") })
    }

    @Test(arguments: [
        ("/usr/bin/tmutil", ["deletelocalsnapshots", "/"]),
        ("/usr/bin/tmutil", ["thinlocalsnapshots", "/", "1", "4"]),
        ("/usr/bin/tmutil", ["listlocalsnapshots", "/", "extra"]),
        ("/usr/bin/tmutil", ["listlocalsnapshots"]),
        ("/usr/bin/xcrun", ["simctl", "delete", "unavailable"]),
        ("/usr/bin/xcrun", ["simctl", "runtime", "delete", "X"]),
        ("/usr/sbin/diskutil", ["eraseDisk", "APFS", "X", "disk9"]),
        ("/bin/echo", ["hello"]),
        ("/bin/rm", ["-rf", "/nonexistent"]),
    ])
    func refusesAnythingNotListedWithoutLaunching(executable: String, arguments: [String]) async {
        let result = await ReadOnlyCommand.run(executable, arguments, timeout: .seconds(5))
        #expect(result.launchError?.hasPrefix("refused") == true)
        #expect(result.exitCode == nil)
        #expect(!result.timedOut)
        #expect(!result.succeeded)
        #expect(result.stdout.isEmpty && result.stderr.isEmpty)
        #expect(result.duration == .zero)
    }

    @Test func refusesARelativeExecutablePath() async {
        let result = await ReadOnlyCommand.run("tmutil", ["listlocalsnapshots", "/"], timeout: .seconds(5))
        #expect(result.launchError?.contains("absolute") == true)
        #expect(result.exitCode == nil)
        #expect(result.duration == .zero)
    }

    @Test func theInternalRunnerAlsoRefusesARelativePath() async {
        let result = await ReadOnlyCommand.execute("sleep", ["0"], timeout: .seconds(5))
        #expect(result.launchError?.contains("absolute") == true)
        #expect(result.exitCode == nil)
    }

    // MARK: Environment

    @Test func environmentIsExactlyPathHomeAndLang() {
        let environment = ReadOnlyCommand.scrubbedEnvironment()
        #expect(environment["PATH"] == "/usr/bin:/bin")
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(environment["HOME"] == NSHomeDirectory())
        #expect(Set(environment.keys) == ["PATH", "HOME", "LANG"])
    }

    @Test func developerDirIsNeverPassedOn() {
        // Whatever the app's own environment holds, the child never gets it (scanner review #10).
        #expect(ReadOnlyCommand.scrubbedEnvironment()["DEVELOPER_DIR"] == nil)
    }

    @Test func aChildSeesOnlyTheScrubbedEnvironment() async {
        let result = await ReadOnlyCommand.execute("/usr/bin/env", [], timeout: .seconds(10))
        #expect(result.succeeded)
        let names = Set(result.stdoutString.split(separator: "\n").compactMap { $0.split(separator: "=").first.map(String.init) })
        // `env` itself may add `_` or `__CF_USER_TEXT_ENCODING`; nothing else may appear.
        let allowed: Set<String> = ["PATH", "HOME", "LANG", "_", "__CF_USER_TEXT_ENCODING", "PWD", "SHLVL"]
        #expect(names.isSubset(of: allowed), "unexpected variables: \(names.subtracting(allowed))")
        #expect(names.contains("PATH"))
        #expect(!names.contains("DEVELOPER_DIR"))
    }

    @Test func simctlIsStillFoundWithTheScrubbedEnvironment() async {
        // xcrun must find simctl through `xcode-select` alone. Skipped on a Mac without Xcode.
        let result = await ReadOnlyCommand.run(
            "/usr/bin/xcrun", ["simctl", "list", "devices", "--json"], timeout: .seconds(30))
        if let error = result.probeError(tool: "xcrun"), error == .toolMissing("xcrun") { return }
        #expect(result.succeeded, "xcrun simctl failed: \(result.stderrString.prefix(200))")
    }

    // MARK: Process handling

    @Test func timeoutStopsASlowCommand() async {
        let result = await ReadOnlyCommand.execute("/bin/sleep", ["5"], timeout: .milliseconds(200))
        #expect(result.timedOut)
        #expect(!result.succeeded)
        #expect(result.duration < timingBudget(.seconds(3)))
        #expect(result.launchError == nil)
    }

    // MARK: Cancellation (scanner review #8) and SIGKILL (#9)

    @Test func cancellingTheCallerStopsTheCommand() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task { await ReadOnlyCommand.execute("/bin/sleep", ["30"], timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = await task.value

        #expect(result.cancelled)
        #expect(!result.timedOut)
        #expect(!result.succeeded)
        #expect(result.probeError(tool: "sleep") == .notRun("cancelled"))
        #expect(started.duration(to: clock.now) < timingBudget(.seconds(5)))
    }

    @Test func aCallerCancelledBeforeTheStartNeverLaunchesTheCommand() async {
        let task = Task { () -> CommandResult in
            while !Task.isCancelled { await Task.yield() }
            return await ReadOnlyCommand.execute("/bin/sleep", ["30"], timeout: .seconds(30))
        }
        task.cancel()
        let started = ContinuousClock().now
        let result = await task.value

        #expect(result.cancelled)
        #expect(result.exitCode == nil)
        #expect(result.launchError == nil)
        #expect(started.duration(to: ContinuousClock().now) < timingBudget(.seconds(5)))
    }

    @Test func aCancelledCommandThatIgnoresTerminateIsStillKilled() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task {
            await SupervisedProcess.run(
                "/usr/bin/perl", ["-e", "$SIG{TERM} = 'IGNORE'; sleep 30"], environment: ["PATH": "/usr/bin:/bin"],
                timeout: .seconds(30), terminateGrace: .milliseconds(300), mergeOutput: false, stopOnCancel: true)
        }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        let outcome = await task.value

        #expect(outcome.cancelled)
        #expect(outcome.terminationStatus == SIGKILL)
        #expect(started.duration(to: clock.now) < timingBudget(.seconds(8)))
    }

    @Test func aRunWithoutStopOnCancelKeepsRunningWhenTheCallerIsCancelled() async throws {
        let task = Task {
            await SupervisedProcess.run(
                "/bin/sh", ["-c", "sleep 1; echo done"], environment: ["PATH": "/usr/bin:/bin"],
                timeout: .seconds(30), terminateGrace: .seconds(1), mergeOutput: false)
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let outcome = await task.value

        #expect(!outcome.cancelled)
        #expect(outcome.terminationStatus == 0)
        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "done\n")
    }

    @Test func largeOutputOnBothPipesDoesNotDeadlock() async {
        // 8 MiB on stdout is far past the 64 KiB pipe buffer; the error message adds a little on stderr.
        let result = await ReadOnlyCommand.execute(
            "/bin/dd", ["if=/dev/zero", "bs=1048576", "count=8"], timeout: .seconds(20)
        )
        #expect(result.succeeded)
        #expect(result.stdout.count == 8 * 1_048_576)
        #expect(result.stderrString.contains("records in"))
    }

    @Test func standardInputIsClosed() async {
        // `cat` with no file argument reads stdin; with /dev/null it ends at once.
        let result = await ReadOnlyCommand.execute("/bin/cat", [], timeout: .seconds(5))
        #expect(result.succeeded)
        #expect(result.stdout.isEmpty)
    }

    @Test func missingExecutableIsALaunchError() async {
        let result = await ReadOnlyCommand.execute("/nonexistent/tool", [], timeout: .seconds(5))
        #expect(result.launchError != nil)
        #expect(result.exitCode == nil)
        #expect(result.probeError(tool: "tool") == .toolMissing("tool"))
    }

    @Test func aRealAllowListedCommandRuns() async {
        let result = await ReadOnlyCommand.run("/usr/sbin/diskutil", ["info", "-plist", "/"], timeout: .seconds(20))
        #expect(result.launchError == nil)
        #expect(result.exitCode == 0)
        #expect(!result.stdout.isEmpty)
    }

    // MARK: Failure mapping

    private func result(
        exit: Int32? = 0, timedOut: Bool = false, launchError: String? = nil, stderr: String = ""
    ) -> CommandResult {
        CommandResult(
            exitCode: exit, timedOut: timedOut, launchError: launchError,
            stdout: Data(), stderr: Data(stderr.utf8), duration: .zero
        )
    }

    @Test func successMapsToNoError() {
        #expect(result().probeError(tool: "x") == nil)
    }

    @Test func timeoutMapsToTimedOut() {
        #expect(result(exit: 15, timedOut: true).probeError(tool: "x") == .timedOut)
    }

    @Test func refusalMapsToNotRun() {
        let refused = result(exit: nil, launchError: "refused: not on the read-only allow-list")
        #expect(refused.probeError(tool: "x") == .notRun("not on the read-only allow-list"))
    }

    @Test(arguments: [
        "xcrun: error: invalid active developer path (/Library/Developer/CommandLineTools), missing xcrun at: /x",
        "xcrun: error: unable to find utility \"simctl\", not a developer tool or in PATH",
        "xcode-select: error: no developer tools were found at '/Applications/Xcode.app'",
    ])
    func missingXcodeMapsToToolMissing(stderr: String) {
        #expect(result(exit: 72, stderr: stderr).probeError(tool: "xcrun") == .toolMissing("xcrun"))
    }

    @Test func otherFailuresKeepTheExitCodeAndMessage() {
        let failed = result(exit: 3, stderr: "boom\n")
        #expect(failed.probeError(tool: "x") == .commandFailed(exitCode: 3, detail: "boom"))
    }

    @Test func aCommandThatCouldNotBeStoppedIsAnError() {
        #expect(result(exit: nil).probeError(tool: "x") != nil)
    }
}
