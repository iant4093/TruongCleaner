import CleanerScanner
import CleanerTestSupport
import Foundation

@testable import CleanerActions

/// A shell script in a fixture folder that stands in for a real tool (`brew`, `docker`, `xcrun`).
/// It records its argv and environment to a log file next to it, then behaves as configured.
/// Tests never run the real tools.
struct FakeTool {
    /// What one launch of the script saw.
    struct Record: Equatable {
        var arguments: [String]
        var environment: [String: String]
    }

    /// Variables the shell adds by itself. Ignored when comparing environments.
    static let shellNoise: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_", "__CF_USER_TEXT_ENCODING"]

    let path: String
    let url: URL
    private let log: URL

    /// Creates `<folder>/<name>` in the tree.
    ///
    /// - Parameters:
    ///   - exitCode: Exit status of a normal run.
    ///   - infoExitCode: Exit status when the first argument is `info` (the Docker reachability check).
    ///   - stdout: Text written to standard output.
    ///   - stderr: Text written to standard error, after `stdout`.
    ///   - filler: Number of `a` bytes written to standard output before `stdout`.
    ///   - sleeps: Replace the process with `sleep 30` (for timeout tests).
    ///   - mode: POSIX permissions of the script.
    static func make(
        in tree: FixtureTree, folder: String, name: String,
        exitCode: Int32 = 0, infoExitCode: Int32? = nil,
        stdout: String? = nil, stderr: String? = nil, filler: Int = 0,
        sleeps: Bool = false, mode: Int = 0o755
    ) throws -> FakeTool {
        let scriptURL = try tree.addFile("\(folder)/\(name)")
        let logURL = tree.url(for: "\(folder)/\(name).log")
        var lines = [
            "#!/bin/sh",
            "{",
            "  echo RUN",
            "  for a in \"$@\"; do echo \"ARG=$a\"; done",
            "  /usr/bin/env | while IFS= read -r l; do echo \"ENV=$l\"; done",
            "} >> '\(logURL.path)'",
        ]
        if let infoExitCode {
            lines.append("if [ \"$1\" = info ]; then exit \(infoExitCode); fi")
        }
        if filler > 0 {
            lines.append("/usr/bin/head -c \(filler) /dev/zero | LC_ALL=C /usr/bin/tr '\\0' a")
        }
        if let stdout { lines.append("printf '%s\\n' '\(stdout)'") }
        if let stderr { lines.append("printf '%s\\n' '\(stderr)' >&2") }
        if sleeps { lines.append("exec /bin/sleep 30") }
        lines.append("exit \(exitCode)")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: scriptURL)
        try tree.setPermissions("\(folder)/\(name)", mode: mode)
        return FakeTool(path: scriptURL.path, url: scriptURL, log: logURL)
    }

    /// Every launch so far, in order. Empty when the script never ran.
    func records() -> [Record] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        var records: [Record] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "RUN" {
                records.append(Record(arguments: [], environment: [:]))
            } else if line.hasPrefix("ARG="), !records.isEmpty {
                records[records.count - 1].arguments.append(String(line.dropFirst(4)))
            } else if line.hasPrefix("ENV="), !records.isEmpty {
                let pair = line.dropFirst(4)
                guard let equals = pair.firstIndex(of: "=") else { continue }
                let key = String(pair[pair.startIndex..<equals])
                if !Self.shellNoise.contains(key) {
                    records[records.count - 1].environment[key] = String(pair[pair.index(after: equals)...])
                }
            }
        }
        return records
    }
}

/// Builds runners that only know fake tools.
enum OwnerTestSupport {
    static func definition(
        _ id: OwnerCommandID, candidates: [String], arguments: [String],
        timeout: Duration = .seconds(20), preflight: Preflight = .none
    ) -> OwnerCommandDefinition {
        OwnerCommandDefinition(
            id: id, candidates: candidates, arguments: arguments, timeout: timeout, preflight: preflight
        )
    }

    static func device(_ udid: String, state: String = "Shutdown") -> SimulatorDevice {
        SimulatorDevice(
            udid: udid, name: "iPhone", runtimeID: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            state: state, isAvailable: true, dataPath: nil, lastBootedAt: nil
        )
    }

    static func runtime(_ identifier: String) -> SimulatorRuntime {
        SimulatorRuntime(
            identifier: identifier, name: "iOS 27.0", version: "27.0",
            sizeBytes: nil, lastUsedAt: nil, isDeletable: true
        )
    }

    /// A runner over `definitions` with canned simulator lists and process state.
    static func runner(
        _ definitions: [OwnerCommandDefinition],
        xcrun: [String] = [],
        devices: Result<[SimulatorDevice], ProbeError> = .success([]),
        runtimes: Result<[SimulatorRuntime], ProbeError> = .success([]),
        processRunning: Bool? = false
    ) -> OwnerCommandRunner {
        OwnerCommandRunner(
            definitions: Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) }),
            xcrunCandidates: xcrun,
            devices: { devices },
            runtimes: { runtimes },
            isProcessRunning: { _ in processRunning }
        )
    }
}
