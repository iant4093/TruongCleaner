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

    @Test func environmentIsScrubbed() {
        let parent = ["PATH": "/evil", "HOME": "/evil", "LANG": "xx", "SECRET_TOKEN": "x", "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"]
        let environment = ReadOnlyCommand.scrubbedEnvironment(parent: parent)
        #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(environment["HOME"] == NSHomeDirectory())
        #expect(environment["DEVELOPER_DIR"] == "/Applications/Xcode.app/Contents/Developer")
        #expect(Set(environment.keys) == ["PATH", "HOME", "LANG", "DEVELOPER_DIR"])
    }

    @Test func developerDirIsOmittedWhenTheParentHasNone() {
        let environment = ReadOnlyCommand.scrubbedEnvironment(parent: ["PATH": "/x"])
        #expect(Set(environment.keys) == ["PATH", "HOME", "LANG"])
    }

    @Test func aChildSeesOnlyTheScrubbedEnvironment() async {
        let result = await ReadOnlyCommand.execute("/usr/bin/env", [], timeout: .seconds(10))
        #expect(result.succeeded)
        let names = Set(result.stdoutString.split(separator: "\n").compactMap { $0.split(separator: "=").first.map(String.init) })
        // `env` itself may add `_` or `__CF_USER_TEXT_ENCODING`; nothing else may appear.
        let allowed: Set<String> = ["PATH", "HOME", "LANG", "DEVELOPER_DIR", "_", "__CF_USER_TEXT_ENCODING", "PWD", "SHLVL"]
        #expect(names.isSubset(of: allowed), "unexpected variables: \(names.subtracting(allowed))")
        #expect(names.contains("PATH"))
    }

    // MARK: Process handling

    @Test func timeoutStopsASlowCommand() async {
        let result = await ReadOnlyCommand.execute("/bin/sleep", ["5"], timeout: .milliseconds(200))
        #expect(result.timedOut)
        #expect(!result.succeeded)
        #expect(result.duration < .seconds(3))
        #expect(result.launchError == nil)
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
