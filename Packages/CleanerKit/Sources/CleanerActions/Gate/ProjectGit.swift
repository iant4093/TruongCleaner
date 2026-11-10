import Foundation

/// Whether git tracks a path.
public enum GitTracking: Sendable, Equatable {
    /// At least one file at or below the path is in the repository's index.
    case tracked
    /// Git says nothing at or below the path is tracked.
    case untracked
    /// The answer could not be had: git is missing, failed or timed out. Holds a short reason.
    case unknown(String)
}

/// Asks git whether a path is tracked. The gate asks it for `dev.projectArtifacts`.
public protocol GitTrackingProbe: Sendable {
    /// Whether `relativePath` (relative to `repository`) is tracked by the repository at `repository`.
    func tracking(of relativePath: String, inRepository repository: URL) async -> GitTracking
}

/// The production probe: `/usr/bin/git ls-files -z --error-unmatch -- <path>`.
///
/// The executable is fixed. The only variable parts of the argument list are the repository folder and
/// the path inside it, both taken from real paths the gate resolved. `--literal-pathspecs` stops git
/// from reading `*` or `:(magic)` in a folder name. `core.fsmonitor=false` stops a repository's own
/// configuration from starting a program. The environment is the scrubbed owner-command one. A
/// timeout, an unexpected exit code or unexpected output is `.unknown`.
public struct GitCommandProbe: GitTrackingProbe {
    /// The fixed executable.
    static let executable = "/usr/bin/git"

    /// Longest the command may run.
    static let timeout: Duration = .seconds(10)

    /// What git prints when a path matches nothing in the index.
    private static let untrackedMessage = "did not match any file(s) known to git"

    /// Creates a probe.
    public init() {}

    /// Runs git and reads its answer.
    @concurrent
    public func tracking(of relativePath: String, inRepository repository: URL) async -> GitTracking {
        guard !relativePath.isEmpty, !relativePath.utf8.contains(0) else { return .unknown("bad path") }
        guard OwnerProcess.check(executable: Self.executable) == .ok else { return .unknown("git not available") }
        let arguments = Self.arguments(for: relativePath, repository: repository)
        let outcome = await OwnerProcess.run(Self.executable, arguments, timeout: Self.timeout)
        if let launchError = outcome.launchError { return .unknown("could not start git: \(launchError)") }
        if outcome.timedOut { return .unknown("git timed out") }
        switch outcome.exitCode {
        case 0?:
            return .tracked
        case 1?:
            let text = OwnerProcess.tailText(outcome.tail)
            return text.contains(Self.untrackedMessage) ? .untracked : .unknown("unexpected git output")
        default:
            return .unknown("git failed")
        }
    }

    /// The argument list, without the executable.
    static func arguments(for relativePath: String, repository: URL) -> [String] {
        [
            "--literal-pathspecs", "-c", "core.fsmonitor=false",
            "-C", repository.path(percentEncoded: false),
            "ls-files", "-z", "--error-unmatch", "--", relativePath,
        ]
    }
}
