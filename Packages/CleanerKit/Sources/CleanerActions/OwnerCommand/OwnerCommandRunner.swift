import CleanerScanner
import Foundation

/// Runs the fixed cleanup commands that some rules delegate to (`REQ-CLEAN-07`, `safety.md` rule 14).
///
/// Only commands on ``OwnerCommands/all`` can run, plus the two per-item simulator deletions that
/// validate their one argument. Each run uses an absolute executable path, a fixed argv, a scrubbed
/// environment, stdin from `/dev/null` and a timeout; never a shell. Anything uncertain (tool missing,
/// preflight unclear, simulator list unreadable) is reported as skipped and nothing is launched
/// (`REQ-SAFE-12`).
public struct OwnerCommandRunner: Sendable {
    private let definitions: [OwnerCommandID: OwnerCommandDefinition]
    private let xcrunCandidates: [String]
    private let devices: @Sendable () async -> Result<[SimulatorDevice], ProbeError>
    private let runtimes: @Sendable () async -> Result<[SimulatorRuntime], ProbeError>
    /// `true` = a process with that name is running, `false` = none is, `nil` = cannot tell.
    private let isProcessRunning: @Sendable (String) -> Bool?

    /// Creates the runner with the real allow-list.
    public init() {
        self.init(
            definitions: OwnerCommands.all,
            xcrunCandidates: ["/usr/bin/xcrun"],
            devices: { await Simulators.devices() },
            runtimes: { await Simulators.runtimes() },
            isProcessRunning: { name in
                switch ProcessNameOwnerProvider.isProcessRunning(named: name) {
                case .running: true
                case .notRunning: false
                default: nil
                }
            }
        )
    }

    /// Creates a runner with injected tables and probes. Tests point this at fake scripts.
    init(
        definitions: [OwnerCommandID: OwnerCommandDefinition],
        xcrunCandidates: [String],
        devices: @escaping @Sendable () async -> Result<[SimulatorDevice], ProbeError>,
        runtimes: @escaping @Sendable () async -> Result<[SimulatorRuntime], ProbeError>,
        isProcessRunning: @escaping @Sendable (String) -> Bool?
    ) {
        self.definitions = definitions
        self.xcrunCandidates = xcrunCandidates
        self.devices = devices
        self.runtimes = runtimes
        self.isProcessRunning = isProcessRunning
    }

    /// Runs an allow-listed command.
    ///
    /// - Parameter id: A key of ``OwnerCommands/all``. Any other ID is skipped without launching anything.
    /// - Returns: What happened. Check ``OwnerCommandResult/skipped`` first, then `timedOut` and `exitCode`.
    @concurrent
    public func run(_ id: OwnerCommandID) async -> OwnerCommandResult {
        guard let definition = definitions[id] else {
            return Self.skipped(id, "not an allowed command", started: ContinuousClock.now)
        }
        return await execute(definition)
    }

    /// Deletes one simulator device with `xcrun simctl delete <udid>`.
    ///
    /// The UDID must look like one (`^[0-9A-F-]{36}$`), must be in the current `simctl` device list,
    /// and the device must be shut down. Otherwise nothing is launched.
    @concurrent
    public func deleteSimulator(udid: String) async -> OwnerCommandResult {
        let id = OwnerCommandID.simctlDeleteDevice
        let started = ContinuousClock.now
        guard Self.isValidUDID(udid) else {
            return Self.skipped(id, "not a valid simulator ID", started: started)
        }
        switch await devices() {
        case .failure(let error):
            return Self.skipped(id, "could not list simulators: \(error)", started: started)
        case .success(let list):
            guard let device = list.first(where: { $0.udid == udid }) else {
                return Self.skipped(id, "no simulator with that ID", started: started)
            }
            guard device.state == "Shutdown" else {
                return Self.skipped(id, "the simulator is not shut down", started: started)
            }
        }
        return await execute(OwnerCommandDefinition(
            id: id, candidates: xcrunCandidates, arguments: ["simctl", "delete", udid],
            timeout: .seconds(120), preflight: .none
        ))
    }

    /// Deletes one simulator runtime with `xcrun simctl runtime delete <identifier>`.
    ///
    /// The identifier must match `^[A-Za-z0-9.-]{1,128}$`, must not start with `-`, and must be in the
    /// current `simctl` runtime list. Otherwise nothing is launched.
    @concurrent
    public func deleteSimulatorRuntime(identifier: String) async -> OwnerCommandResult {
        let id = OwnerCommandID.simctlDeleteRuntime
        let started = ContinuousClock.now
        guard Self.isValidRuntimeIdentifier(identifier) else {
            return Self.skipped(id, "not a valid runtime identifier", started: started)
        }
        switch await runtimes() {
        case .failure(let error):
            return Self.skipped(id, "could not list runtimes: \(error)", started: started)
        case .success(let list):
            guard list.contains(where: { $0.identifier == identifier }) else {
                return Self.skipped(id, "no runtime with that identifier", started: started)
            }
        }
        return await execute(OwnerCommandDefinition(
            id: id, candidates: xcrunCandidates, arguments: ["simctl", "runtime", "delete", identifier],
            timeout: .seconds(300), preflight: .none
        ))
    }

    // MARK: Argument validation

    /// `^[0-9A-F-]{36}$`, checked byte by byte (no regex, so a trailing newline cannot slip through).
    static func isValidUDID(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 36 && bytes.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
                || byte == UInt8(ascii: "-")
        }
    }

    /// `^[A-Za-z0-9.-]{1,128}$` and no leading `-`, so the value can never read as an option.
    static func isValidRuntimeIdentifier(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1...128).contains(bytes.count), bytes[0] != UInt8(ascii: "-") else { return false }
        return bytes.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
        }
    }

    // MARK: Execution

    private func execute(_ definition: OwnerCommandDefinition) async -> OwnerCommandResult {
        let started = ContinuousClock.now
        let id = definition.id

        let executable: String
        switch Self.resolve(definition.candidates) {
        case .found(let path): executable = path
        case .notFound: return Self.skipped(id, "tool not found", started: started)
        case .refused(let path, let reason):
            return Self.skipped(id, "refused \(path): \(reason)", executable: path, started: started)
        }

        if let failure = await preflightFailure(definition, executable: executable) {
            return Self.skipped(id, failure, executable: executable, started: started)
        }

        let outcome = await OwnerProcess.run(executable, definition.arguments, timeout: definition.timeout)
        if let launchError = outcome.launchError {
            return Self.skipped(id, "could not start: \(launchError)", executable: executable, started: started)
        }
        return OwnerCommandResult(
            id: id, executable: executable, exitCode: outcome.exitCode, timedOut: outcome.timedOut,
            skipped: nil, outputTail: OwnerProcess.tailText(outcome.tail),
            duration: started.duration(to: ContinuousClock.now)
        )
    }

    private enum Resolution {
        case found(String)
        case notFound
        case refused(path: String, reason: String)
    }

    /// The first candidate that exists decides. If it fails the checks, the command is refused;
    /// a later candidate is not tried.
    private static func resolve(_ candidates: [String]) -> Resolution {
        for path in candidates {
            switch OwnerProcess.check(executable: path) {
            case .missing: continue
            case .ok: return .found(path)
            case .refused(let reason): return .refused(path: path, reason: reason)
            }
        }
        return .notFound
    }

    /// The reason the preflight failed, or `nil` when it passed. "Cannot tell" is a failure.
    private func preflightFailure(_ definition: OwnerCommandDefinition, executable: String) async -> String? {
        switch definition.preflight {
        case .none:
            return nil
        case .noBootedSimulator:
            switch await devices() {
            case .failure(let error):
                return "could not check simulators: \(error)"
            case .success(let list):
                return list.contains { $0.state != "Shutdown" } ? "a simulator is running" : nil
            }
        case .dockerReachable:
            let check = OwnerCommands.dockerInfo(candidates: [executable])
            let outcome = await OwnerProcess.run(executable, check.arguments, timeout: check.timeout)
            let reachable = outcome.launchError == nil && !outcome.timedOut && outcome.exitCode == 0
            return reachable ? nil : "Docker is not running"
        case .processNotRunning(let name):
            switch isProcessRunning(name) {
            case true?: return "\(name) is running"
            case false?: return nil
            case nil: return "could not tell whether \(name) is running"
            }
        }
    }

    private static func skipped(
        _ id: OwnerCommandID, _ reason: String, executable: String? = nil,
        started: ContinuousClock.Instant
    ) -> OwnerCommandResult {
        OwnerCommandResult(
            id: id, executable: executable, exitCode: nil, timedOut: false, skipped: reason,
            outputTail: "", duration: started.duration(to: ContinuousClock.now)
        )
    }
}
