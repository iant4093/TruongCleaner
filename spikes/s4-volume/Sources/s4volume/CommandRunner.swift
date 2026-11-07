import Foundation
import Synchronization

/// Result of one read-only command.
struct CommandResult: Sendable {
    let argv: [String]
    let exitCode: Int32?
    let terminationReason: String?
    let timedOut: Bool
    let launchError: String?
    let seconds: Double
    let stdout: Data
    let stderr: Data

    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    var succeeded: Bool { exitCode == 0 && !timedOut && launchError == nil }

    /// Command record for the report. Large plist/JSON outputs are summarized by size only.
    func json(includeStdout: Bool) -> JSONValue {
        var object: [String: JSONValue] = [
            "argv": .array(argv.map { .string($0) }),
            "exitCode": exitCode.map { .int(Int64($0)) } ?? .null,
            "terminationReason": terminationReason.map { .string($0) } ?? .null,
            "timedOut": .bool(timedOut),
            "launchError": launchError.map { .string($0) } ?? .null,
            "seconds": .double((seconds * 1000).rounded() / 1000),
            "stdoutBytes": .bytes(stdout.count),
            "stderr": .string(stderrString.trimmingCharacters(in: .whitespacesAndNewlines)),
        ]
        if includeStdout {
            object["stdout"] = .string(stdoutString)
        }
        return .object(object)
    }
}

private final class PipeBuffer: Sendable {
    private let storage = Mutex<Data>(Data())
    func set(_ data: Data) { storage.withLock { $0 = data } }
    var data: Data { storage.withLock { $0 } }
}

/// Runs the fixed list of read-only commands this spike needs.
/// Absolute path, argv array, scrubbed environment, timeout, no shell.
/// Anything not on the allow-list is refused without being launched.
enum CommandRunner {
    /// Executable -> the only argv lists allowed for it. `tmutil` appears with list verbs only.
    static let allowList: [String: [[String]]] = [
        "/usr/bin/tmutil": [
            ["listlocalsnapshots", "/"],
            ["listlocalsnapshotdates", "/"],
        ],
        "/usr/sbin/diskutil": [
            ["apfs", "list", "-plist"],
            ["info", "-plist", "/"],
        ],
        "/usr/sbin/sysctl": [
            ["-n", "vm.swapusage"],
        ],
        "/usr/sbin/system_profiler": [
            ["SPStorageDataType", "-json"],
        ],
    ]

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        let argv = [executable] + arguments
        guard let allowedArguments = allowList[executable], allowedArguments.contains(arguments) else {
            return CommandResult(
                argv: argv, exitCode: nil, terminationReason: nil, timedOut: false,
                launchError: "refused: not on the read-only allow-list", seconds: 0,
                stdout: Data(), stderr: Data()
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
        ]
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        let started = Date()
        do {
            try process.run()
        } catch {
            return CommandResult(
                argv: argv, exitCode: nil, terminationReason: nil, timedOut: false,
                launchError: error.localizedDescription, seconds: Date().timeIntervalSince(started),
                stdout: Data(), stderr: Data()
            )
        }

        // Drain both pipes concurrently so a large output cannot block the child.
        let outBuffer = PipeBuffer()
        let errBuffer = PipeBuffer()
        let readers = DispatchGroup()
        for (handle, buffer) in [(outPipe.fileHandleForReading, outBuffer), (errPipe.fileHandleForReading, errBuffer)] {
            readers.enter()
            DispatchQueue.global().async {
                buffer.set((try? handle.readToEnd()) ?? Data())
                readers.leave()
            }
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        _ = readers.wait(timeout: .now() + 5)

        let finished = !process.isRunning
        let reason: String? = finished
            ? (process.terminationReason == .uncaughtSignal ? "uncaughtSignal" : "exit")
            : nil
        return CommandResult(
            argv: argv,
            exitCode: finished ? process.terminationStatus : nil,
            terminationReason: reason,
            timedOut: timedOut,
            launchError: nil,
            seconds: Date().timeIntervalSince(started),
            stdout: outBuffer.data,
            stderr: errBuffer.data
        )
    }
}
