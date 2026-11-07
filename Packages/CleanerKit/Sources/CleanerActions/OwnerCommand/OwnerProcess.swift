import CleanerScanner
import Darwin
import Foundation

/// How a launched owner command ended. Internal; ``OwnerCommandRunner`` turns it into an ``OwnerCommandResult``.
struct OwnerProcessOutcome: Sendable {
    /// Exit status when the process exited by itself.
    var exitCode: Int32?
    var timedOut: Bool
    /// Set when the process could not be started.
    var launchError: String?
    /// The last ``OwnerProcess/tailLimit`` bytes of stdout and stderr together.
    var tail: Data
}

/// Process launch with the strictness of `safety.md` rule 14.
///
/// No shell, stdin from `/dev/null`, a given environment, a timeout (terminate, then kill after
/// 5 s) and both output streams read at once into one bounded buffer.
enum OwnerProcess {
    /// Output kept for the result.
    static let tailLimit = 4096
    /// How long a terminated process may take to exit before it is killed.
    static let killGrace: Duration = .seconds(5)

    /// Result of checking a candidate path.
    enum ExecutableCheck: Equatable {
        case missing
        case refused(String)
        case ok
    }

    /// Checks that `path` is absolute, resolves (through symlinks) to an executable regular file, and is not world-writable.
    static func check(executable path: String) -> ExecutableCheck {
        guard path.hasPrefix("/") else { return .refused("executable path must be absolute") }
        var info = stat()
        guard stat(path, &info) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .refused("cannot inspect \(path)")
        }
        guard info.st_mode & S_IFMT == S_IFREG else { return .refused("\(path) is not a regular file") }
        guard info.st_mode & S_IWOTH == 0 else { return .refused("\(path) is world-writable") }
        guard access(path, X_OK) == 0 else { return .refused("\(path) is not executable") }
        return .ok
    }

    /// The environment every owner command gets: nothing from the parent except `HOME`.
    static func environment(executable: String) -> [String: String] {
        let url = URL(fileURLWithPath: executable)
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:" + url.deletingLastPathComponent().path,
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
        ]
        switch url.lastPathComponent {
        case "brew":
            environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            environment["HOMEBREW_NO_ANALYTICS"] = "1"
        case "docker":
            environment["DOCKER_CLI_HINTS"] = "false"
        default:
            break
        }
        return environment
    }

    /// Launches `executable` and awaits it. No thread is held while it runs
    /// (see ``SupervisedProcess``), so many owner commands cost no more threads than one.
    @concurrent
    static func run(
        _ executable: String, _ arguments: [String], timeout: Duration
    ) async -> OwnerProcessOutcome {
        let outcome = await SupervisedProcess.run(
            executable, arguments, environment: environment(executable: executable),
            timeout: timeout, terminateGrace: killGrace, mergeOutput: true, keepLast: tailLimit)
        return OwnerProcessOutcome(
            exitCode: outcome.exitedNormally ? outcome.terminationStatus : nil,
            timedOut: outcome.timedOut,
            launchError: outcome.launchError,
            tail: outcome.launchError == nil ? outcome.stdout : Data()
        )
    }

    /// The last bytes of the output as text. The cut moves forward to the next UTF-8 character start,
    /// so the text is never longer than the limit and never begins with a broken character.
    static func tailText(_ data: Data) -> String {
        var bytes = data.suffix(tailLimit)
        while let first = bytes.first, first & 0b1100_0000 == 0b1000_0000 {
            bytes = bytes.dropFirst()
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
