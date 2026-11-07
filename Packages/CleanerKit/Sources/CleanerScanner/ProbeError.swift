/// Why a read-only system probe produced no answer.
///
/// A probe error never means "zero". Callers show "Unknown" and keep whatever
/// they were going to act on (`safety.md` rule 9).
public enum ProbeError: Error, Sendable, Equatable {
    /// The tool is not installed or not usable (for example Xcode is missing for `xcrun simctl`).
    case toolMissing(String)
    /// The command ran but exited with a failure status.
    case commandFailed(exitCode: Int32, detail: String)
    /// The command did not finish within its timeout and was stopped.
    case timedOut
    /// The command was refused (not on the allow-list) or could not be launched.
    case notRun(String)
    /// The command's output was not in the expected format.
    case parse(String)
}

extension ProbeError: CustomStringConvertible {
    /// A short English description for logs and "Learn more" text.
    public var description: String {
        switch self {
        case .toolMissing(let tool): "\(tool) is not available"
        case .commandFailed(let code, let detail): "command failed (exit \(code)): \(detail)"
        case .timedOut: "command timed out"
        case .notRun(let reason): "command not run: \(reason)"
        case .parse(let reason): "unexpected output: \(reason)"
        }
    }
}
