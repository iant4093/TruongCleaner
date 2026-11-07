import Darwin
import Foundation
import Synchronization

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

/// Blocking process launch with the strictness of `safety.md` rule 14.
///
/// No shell, stdin from `/dev/null`, a given environment, a timeout (terminate, then kill after
/// 5 s) and both output streams read at once into one bounded buffer.
enum OwnerProcess {
    /// Output kept for the result.
    static let tailLimit = 4096
    /// How long a terminated process may take to exit before it is killed.
    static let killGrace: DispatchTimeInterval = .seconds(5)

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

    /// Launches `executable` on a dispatch thread (never the cooperative pool or the main actor).
    @concurrent
    static func run(
        _ executable: String, _ arguments: [String], timeout: Duration
    ) async -> OwnerProcessOutcome {
        let environment = environment(executable: executable)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(
                    executable, arguments, timeout: timeout, environment: environment
                ))
            }
        }
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

    /// Keeps only the newest bytes of a stream.
    private final class TailBuffer: Sendable {
        private let storage = Mutex<Data>(Data())

        func append(_ chunk: Data) {
            storage.withLock { data in
                data.append(chunk)
                if data.count > tailLimit * 2 {
                    data = Data(data.suffix(tailLimit))
                }
            }
        }

        var data: Data { storage.withLock { $0 } }
    }

    private static func runBlocking(
        _ executable: String,
        _ arguments: [String],
        timeout: Duration,
        environment: [String: String]
    ) -> OwnerProcessOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return OwnerProcessOutcome(
                exitCode: nil, timedOut: false, launchError: error.localizedDescription, tail: Data()
            )
        }

        let buffer = TailBuffer()
        let reader = DispatchGroup()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        reader.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = read(descriptor, &chunk, chunk.count)
                if count > 0 {
                    buffer.append(Data(chunk[0..<count]))
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            reader.leave()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + dispatchInterval(timeout)) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + killGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + .seconds(2))
            }
        }
        // A grandchild that kept the pipe open must not hold us up for long.
        _ = reader.wait(timeout: .now() + .seconds(5))

        let exitedNormally = !process.isRunning && process.terminationReason == .exit
        return OwnerProcessOutcome(
            exitCode: exitedNormally ? process.terminationStatus : nil,
            timedOut: timedOut,
            launchError: nil,
            tail: buffer.data
        )
    }

    private static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let parts = duration.components
        let nanoseconds = Double(parts.seconds) * 1e9 + Double(parts.attoseconds) / 1e9
        guard nanoseconds > 0 else { return .nanoseconds(0) }
        return .nanoseconds(Int(min(nanoseconds, Double(Int.max / 2))))
    }
}
