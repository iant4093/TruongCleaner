import Foundation

/// The stable name of one owner command, for example `"simctl.deleteUnavailable"`.
///
/// History records and rules refer to commands by this ID. An ID that is not a key of
/// ``OwnerCommands/all`` (and not one of the two simulator IDs below) cannot run.
public struct OwnerCommandID: RawRepresentable, Hashable, Sendable, Codable {
    /// The ID text.
    public let rawValue: String

    /// Creates an ID from its text.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// `xcrun simctl delete unavailable`
    public static let simctlDeleteUnavailable = OwnerCommandID(rawValue: "simctl.deleteUnavailable")
    /// `brew cleanup --prune=30`
    public static let brewCleanup = OwnerCommandID(rawValue: "brew.cleanup")
    /// `pnpm store prune`
    public static let pnpmStorePrune = OwnerCommandID(rawValue: "pnpm.storePrune")
    /// `go clean -cache`
    public static let goCleanCache = OwnerCommandID(rawValue: "go.cleanCache")
    /// `go clean -modcache`
    public static let goCleanModcache = OwnerCommandID(rawValue: "go.cleanModcache")
    /// `docker image prune -f`
    public static let dockerImagePrune = OwnerCommandID(rawValue: "docker.imagePrune")
    /// `docker builder prune -f --filter until=168h`
    public static let dockerBuilderPrune = OwnerCommandID(rawValue: "docker.builderPrune")

    /// `xcrun simctl delete <UDID>`. Built per device by ``OwnerCommandRunner/deleteSimulator(udid:)``;
    /// not part of ``OwnerCommands/all``.
    public static let simctlDeleteDevice = OwnerCommandID(rawValue: "simctl.deleteDevice")
    /// `xcrun simctl runtime delete <identifier>`. Built per runtime by
    /// ``OwnerCommandRunner/deleteSimulatorRuntime(identifier:)``; not part of ``OwnerCommands/all``.
    public static let simctlDeleteRuntime = OwnerCommandID(rawValue: "simctl.deleteRuntime")

    /// Internal-only: `docker info`, used as the "is the daemon reachable" check. Never in ``OwnerCommands/all``.
    static let dockerInfo = OwnerCommandID(rawValue: "docker.info")
}

/// A check that must pass before an owner command is launched. A check that cannot tell fails.
public enum Preflight: Sendable, Hashable {
    /// No check.
    case none
    /// No simulator device may be in any state other than `Shutdown`.
    case noBootedSimulator
    /// `docker info` must succeed (the daemon answers).
    case dockerReachable
    /// The tool with this name may not be running: no process named so, and no interpreter
    /// (`node`, `ruby`, `bash`, ...) running a script of that name (`node .../pnpm.cjs`).
    /// See ``ProcessOwnerMatcher``.
    case processNotRunning(String)
}

/// One fixed command: executable candidates, exact argv, timeout and preflight.
public struct OwnerCommandDefinition: Sendable, Hashable {
    /// The command's ID.
    public let id: OwnerCommandID
    /// Absolute executable paths, tried in order. The first one that exists is used.
    public let candidates: [String]
    /// The fixed argument list.
    public let arguments: [String]
    /// How long the command may run before it is terminated.
    public let timeout: Duration
    /// The check to pass before launching.
    public let preflight: Preflight

    /// Creates a definition.
    public init(
        id: OwnerCommandID, candidates: [String], arguments: [String],
        timeout: Duration, preflight: Preflight
    ) {
        self.id = id
        self.candidates = candidates
        self.arguments = arguments
        self.timeout = timeout
        self.preflight = preflight
    }
}

/// The allow-list of owner commands (`safety.md` rule 14).
public enum OwnerCommands {
    private static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    private static let pnpmPaths = ["/opt/homebrew/bin/pnpm", "/usr/local/bin/pnpm"]
    private static let goPaths = ["/opt/homebrew/bin/go", "/usr/local/go/bin/go"]
    private static let dockerPaths = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"]

    /// The complete allow-list. Nothing else can run.
    public static let all: [OwnerCommandID: OwnerCommandDefinition] = {
        let definitions = [
            OwnerCommandDefinition(
                id: .simctlDeleteUnavailable, candidates: ["/usr/bin/xcrun"],
                arguments: ["simctl", "delete", "unavailable"], timeout: .seconds(120),
                preflight: .noBootedSimulator
            ),
            OwnerCommandDefinition(
                id: .brewCleanup, candidates: brewPaths,
                arguments: ["cleanup", "--prune=30"], timeout: .seconds(300),
                preflight: .processNotRunning("brew")
            ),
            OwnerCommandDefinition(
                id: .pnpmStorePrune, candidates: pnpmPaths,
                arguments: ["store", "prune"], timeout: .seconds(300),
                preflight: .processNotRunning("pnpm")
            ),
            OwnerCommandDefinition(
                id: .goCleanCache, candidates: goPaths,
                arguments: ["clean", "-cache"], timeout: .seconds(300), preflight: .none
            ),
            OwnerCommandDefinition(
                id: .goCleanModcache, candidates: goPaths,
                arguments: ["clean", "-modcache"], timeout: .seconds(300), preflight: .none
            ),
            OwnerCommandDefinition(
                id: .dockerImagePrune, candidates: dockerPaths,
                arguments: ["image", "prune", "-f"], timeout: .seconds(300),
                preflight: .dockerReachable
            ),
            OwnerCommandDefinition(
                id: .dockerBuilderPrune, candidates: dockerPaths,
                arguments: ["builder", "prune", "-f", "--filter", "until=168h"], timeout: .seconds(300),
                preflight: .dockerReachable
            ),
        ]
        return Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
    }()

    /// The `docker info` check, using the same executable candidates as the command it guards.
    static func dockerInfo(candidates: [String]) -> OwnerCommandDefinition {
        OwnerCommandDefinition(
            id: .dockerInfo, candidates: candidates,
            arguments: ["info", "--format", "{{.ServerVersion}}"], timeout: .seconds(10),
            preflight: .none
        )
    }
}

/// What happened when an owner command was asked to run.
///
/// Either the command ran (`exitCode` or `timedOut` tells how it ended) or it did not
/// (`skipped` says why). A skipped command was never launched.
public struct OwnerCommandResult: Sendable, Codable {
    /// The command's ID.
    public let id: OwnerCommandID
    /// The executable that was chosen, or `nil` when none was.
    public let executable: String?
    /// The exit status when the command exited by itself. `nil` when it did not run, timed out or was killed by a signal.
    public let exitCode: Int32?
    /// `true` when the command ran past its timeout and was stopped.
    public let timedOut: Bool
    /// Why the command was not run (tool missing, refused, preflight failed). `nil` when it ran.
    public let skipped: String?
    /// The last 4 KB of standard output and standard error together, as UTF-8.
    public let outputTail: String
    /// Wall-clock time spent on this call, preflight included.
    public let duration: Duration

    /// `true` only when the command ran, exited 0 and did not time out.
    public var succeeded: Bool { skipped == nil && !timedOut && exitCode == 0 }

    /// Creates a result.
    public init(
        id: OwnerCommandID, executable: String?, exitCode: Int32?, timedOut: Bool,
        skipped: String?, outputTail: String, duration: Duration
    ) {
        self.id = id
        self.executable = executable
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.skipped = skipped
        self.outputTail = outputTail
        self.duration = duration
    }
}
