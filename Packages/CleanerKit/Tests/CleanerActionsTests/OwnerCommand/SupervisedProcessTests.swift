import CleanerScanner
import CleanerTestSupport
import Darwin
import Foundation
import Testing

/// The launcher under `ReadOnlyCommand` and `OwnerProcess`. These tests use only system tools
/// (`/bin/echo`, `/bin/sleep`, `/bin/sh`, `/usr/bin/perl`) and write nothing.
struct SupervisedProcessTests {
    private let environment = ["PATH": "/usr/bin:/bin"]

    private func run(
        _ executable: String, _ arguments: [String], timeout: Duration = .seconds(10),
        grace: Duration = .seconds(1), merge: Bool = false, keepLast: Int? = nil
    ) async -> SupervisedOutcome {
        await SupervisedProcess.run(
            executable, arguments, environment: environment, timeout: timeout,
            terminateGrace: grace, mergeOutput: merge, keepLast: keepLast)
    }

    /// Threads in this process, from the kernel.
    private func threadCount() -> Int32 {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
        return info.pti_threadnum
    }

    @Test func supervised_collectsStdoutAndStderrSeparately() async {
        let outcome = await run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "out\n")
        #expect(String(decoding: outcome.stderr, as: UTF8.self) == "err\n")
        #expect(outcome.terminationStatus == 3)
        #expect(outcome.exitedNormally)
        #expect(!outcome.timedOut)
        #expect(outcome.launchError == nil)
    }

    @Test func supervised_mergedOutputComesInOneStream() async {
        let outcome = await run("/bin/sh", ["-c", "echo out; echo err >&2"], merge: true)
        let text = String(decoding: outcome.stdout, as: UTF8.self)
        #expect(text.contains("out") && text.contains("err"))
        #expect(outcome.stderr.isEmpty)
    }

    @Test func supervised_keepLastBoundsMemoryAndKeepsTheEnd() async {
        // 200,000 bytes of "a" followed by "END".
        let outcome = await run(
            "/bin/sh", ["-c", "/usr/bin/head -c 200000 /dev/zero | /usr/bin/tr '\\0' a; echo END"], keepLast: 1000)
        #expect(outcome.stdout.count <= 2000)
        #expect(String(decoding: outcome.stdout.suffix(4), as: UTF8.self) == "END\n")
    }

    @Test func supervised_missingExecutableIsALaunchErrorNotACrash() async {
        let outcome = await run("/nonexistent/tool-tc", [])
        #expect(outcome.launchError != nil)
        #expect(outcome.terminationStatus == nil)
    }

    @Test func supervised_timeoutTerminatesAndReportsIt() async {
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await run("/bin/sleep", ["30"], timeout: .milliseconds(300))
        #expect(outcome.timedOut)
        #expect(!outcome.exitedNormally)
        #expect(started.duration(to: clock.now) < timingBudget(.seconds(5)))
    }

    @Test func supervised_aProcessThatIgnoresTerminateIsKilledAfterTheGrace() async {
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await run(
            "/usr/bin/perl", ["-e", "$SIG{TERM} = 'IGNORE'; sleep 30"],
            timeout: .milliseconds(300), grace: .milliseconds(300))
        #expect(outcome.timedOut)
        #expect(outcome.terminationStatus == SIGKILL)
        #expect(!outcome.exitedNormally)
        #expect(started.duration(to: clock.now) < timingBudget(.seconds(5)))
    }

    @Test func supervised_aBurstOfCommandsDoesNotParkAThreadEach() async {
        let commands = 60
        let peak = await withTaskGroup(of: Int32.self) { group -> Int32 in
            for _ in 0..<commands {
                group.addTask {
                    _ = await SupervisedProcess.run(
                        "/bin/sleep", ["0.5"], environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(10),
                        terminateGrace: .seconds(1), mergeOutput: true)
                    return 0
                }
            }
            // All sixty are alive now. The old launcher held three threads for each, 180 in all.
            try? await Task.sleep(for: .milliseconds(250))
            let sampled = threadCount()
            for await _ in group {}
            return sampled
        }
        #expect(peak > 0)
        #expect(peak < 150)
    }
}
