import Foundation

/// The outcome of one read-only command.
public struct CommandResult: Sendable {
    /// Exit status, or `nil` when the command never started or could not be stopped.
    public let exitCode: Int32?
    /// `true` when the command ran past its timeout and was stopped.
    public let timedOut: Bool
    /// `true` when the calling task was cancelled and the command was stopped (or never started) because of it.
    public var cancelled = false
    /// Why the command was refused or could not be launched. `nil` when it ran.
    public let launchError: String?
    /// Everything the command wrote to standard output.
    public let stdout: Data
    /// Everything the command wrote to standard error.
    public let stderr: Data
    /// Wall-clock time from launch request to the end of the call.
    public let duration: Duration

    /// `true` only when the command ran, exited 0 and did not time out.
    public var succeeded: Bool { exitCode == 0 && !timedOut && launchError == nil }

    /// Standard output decoded as UTF-8.
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }

    /// Standard error decoded as UTF-8.
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs the few read-only system commands the scanner needs.
///
/// Rules (`REQ-CLEAN-07`, read-only part): absolute executable path, fixed argv,
/// scrubbed environment, no shell, stdin from `/dev/null`, a timeout. A command
/// that is not on ``allowList`` is refused without being launched.
public struct ReadOnlyCommand: Sendable {
    /// Executable path mapped to the only argument lists allowed for it (exact match).
    public static let allowList: [String: [[String]]] = [
        "/usr/bin/tmutil": [
            ["listlocalsnapshots", "/"],
            ["listlocalsnapshotdates", "/"],
        ],
        "/usr/sbin/diskutil": [
            ["apfs", "list", "-plist"],
            ["info", "-plist", "/"],
        ],
        "/usr/bin/xcrun": [
            ["simctl", "list", "devices", "--json"],
            ["simctl", "runtime", "list", "--json"],
        ],
    ]

    /// `PATH` given to every command (tech.md: exactly `PATH=/usr/bin:/bin`).
    static let searchPath = "/usr/bin:/bin"

    /// Prefix of `launchError` when a command was refused before launch.
    static let refusedPrefix = "refused: "

    /// Runs an allow-listed command.
    ///
    /// - Parameters:
    ///   - executable: Absolute path of the tool.
    ///   - arguments: The exact argument list from ``allowList``.
    ///   - timeout: How long to wait before terminating the command (then killing it after 2 s).
    /// - Returns: The result. A refused command has `launchError` set and was never launched.
    @concurrent
    public static func run(_ executable: String, _ arguments: [String], timeout: Duration) async -> CommandResult {
        guard executable.hasPrefix("/") else {
            return refused("executable path must be absolute")
        }
        guard let allowedArguments = allowList[executable], allowedArguments.contains(arguments) else {
            return refused("not on the read-only allow-list")
        }
        return await execute(executable, arguments, timeout: timeout)
    }

    /// Runs any absolute-path command with the same environment, pipe and timeout handling.
    ///
    /// Internal so tests can exercise the timeout path. The allow-list lives in ``run(_:_:timeout:)``
    /// and tests cannot change it.
    @concurrent
    static func execute(_ executable: String, _ arguments: [String], timeout: Duration) async -> CommandResult {
        guard executable.hasPrefix("/") else {
            return refused("executable path must be absolute")
        }
        let environment = scrubbedEnvironment()
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await SupervisedProcess.run(
            executable, arguments, environment: environment, timeout: timeout,
            terminateGrace: .seconds(2), mergeOutput: false, stopOnCancel: true)
        return CommandResult(
            exitCode: outcome.terminationStatus,
            timedOut: outcome.timedOut,
            cancelled: outcome.cancelled,
            launchError: outcome.launchError,
            stdout: outcome.stdout,
            stderr: outcome.stderr,
            duration: started.duration(to: clock.now)
        )
    }

    /// The environment every command gets: `PATH`, `HOME` and `LANG`, nothing from the parent process.
    ///
    /// `DEVELOPER_DIR` is not passed on. `xcrun` runs the tool it finds under that folder, so an inherited
    /// value would choose which `simctl` runs. Without it `xcrun` uses the Xcode selected with `xcode-select`.
    static func scrubbedEnvironment() -> [String: String] {
        [
            "PATH": searchPath,
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
        ]
    }

    private static func refused(_ reason: String) -> CommandResult {
        CommandResult(
            exitCode: nil, timedOut: false, launchError: refusedPrefix + reason,
            stdout: Data(), stderr: Data(), duration: .zero
        )
    }
}

extension CommandResult {
    /// The `ProbeError` for a command that did not succeed, or `nil` when it did.
    ///
    /// - Parameter tool: Name shown in `toolMissing` errors (for example `"xcrun"`).
    func probeError(tool: String) -> ProbeError? {
        if cancelled { return .notRun("cancelled") }
        if let launchError {
            return launchError.hasPrefix(ReadOnlyCommand.refusedPrefix)
                ? .notRun(String(launchError.dropFirst(ReadOnlyCommand.refusedPrefix.count)))
                : .toolMissing(tool)
        }
        if timedOut { return .timedOut }
        guard let exitCode else { return .commandFailed(exitCode: -1, detail: "command did not stop") }
        if exitCode == 0 { return nil }

        let message = stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = message.lowercased()
        let missingMarkers = [
            "invalid active developer path",
            "unable to find utility",
            "no developer tools were found",
            "active developer directory",
            "xcode-select: error",
        ]
        if missingMarkers.contains(where: lowered.contains) { return .toolMissing(tool) }
        return .commandFailed(exitCode: exitCode, detail: String(message.suffix(200)))
    }
}
