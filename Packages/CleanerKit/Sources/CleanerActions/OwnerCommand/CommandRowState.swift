import CleanerCore
import Foundation

// Pure decisions behind the Developer and History pages: which button is on, what the row says, what
// the confirmation says. They live here so tests can reach them; the pages only draw the result.

/// Where the simulator lists stand.
public enum SimulatorListStatus: Sendable, Equatable {
    /// Not read yet.
    case notLoaded
    /// Being read.
    case loading
    /// Read.
    case ready
    /// Cannot be read. Holds the reason in plain words.
    case unavailable(String)
}

/// What the trailing side of a command row shows, and the note under it.
///
/// A command row has a Run button. The button is on only when the tool is installed, nothing blocks
/// the command, and nothing else is running. Unknown (`isInstalled == nil`) keeps it off.
public struct DeveloperRowState: Sendable, Equatable {
    /// What the row shows on its trailing side.
    public enum Trailing: Sendable, Equatable {
        /// A spinner: this command is running now.
        case running
        /// The text ``DeveloperRowState/notInstalledText``.
        case notInstalled
        /// A Run button, on or off.
        case run(isEnabled: Bool)
    }

    /// The text shown when the tool is not on this Mac.
    public static let notInstalledText = "Not installed"

    /// What the trailing side shows.
    public let trailing: Trailing
    /// A line under the row that says why the command cannot run now, or `nil`.
    /// It is left out when the tool is not installed, because that says enough.
    public let note: String?

    /// Decides a row.
    ///
    /// - Parameters:
    ///   - isInstalled: Whether the tool is on this Mac. `nil` until it has been looked for.
    ///   - isRunning: This command is running now.
    ///   - isBusy: Any command, scan or clean is running.
    ///   - blockReason: Why the command must not run now (a simulator is running), or `nil`.
    public init(isInstalled: Bool?, isRunning: Bool, isBusy: Bool, blockReason: String?) {
        if isRunning {
            trailing = .running
        } else if isInstalled == false {
            trailing = .notInstalled
        } else {
            trailing = .run(isEnabled: isInstalled == true && blockReason == nil && !isBusy)
        }
        note = isInstalled == false ? nil : blockReason
    }

    // MARK: Simulators

    /// Why simulators cannot be deleted now, or `nil` when they can.
    ///
    /// - Parameters:
    ///   - status: Where the simulator lists stand.
    ///   - anySimulatorRunning: Some simulator is in a state other than shut down.
    public static func simulatorBlockReason(status: SimulatorListStatus, anySimulatorRunning: Bool) -> String? {
        switch status {
        case .notLoaded, .loading: "Reading the simulator list…"
        case .unavailable(let message): message
        case .ready: anySimulatorRunning ? "A simulator is running. Quit Simulator first." : nil
        }
    }

    /// Why one simulator device cannot be deleted now, or `nil` when it can.
    public static func deviceDeleteBlockReason(isBusy: Bool, isShutDown: Bool) -> String? {
        if isBusy { return "Something else is running." }
        return isShutDown ? nil : "This simulator is running. Shut it down first."
    }

    /// Why one simulator runtime cannot be deleted now, or `nil` when it can. A running simulator may use it.
    ///
    /// - Parameters:
    ///   - isBusy: Any command, scan or clean is running.
    ///   - isDeletable: `simctl` says the runtime can be deleted.
    ///   - simulatorBlockReason: The result of ``simulatorBlockReason(status:anySimulatorRunning:)``.
    public static func runtimeDeleteBlockReason(
        isBusy: Bool, isDeletable: Bool, simulatorBlockReason: String?
    ) -> String? {
        if isBusy { return "Something else is running." }
        if !isDeletable { return "Xcode says this runtime cannot be deleted." }
        return simulatorBlockReason
    }
}

/// What the user is asked to confirm before a command runs: the title, the button and the exact command.
public enum DeveloperConfirmation: Sendable, Equatable {
    /// An allow-listed command. `commandText` is the exact command line, one per line.
    case command(title: String, commandText: String)
    /// `simctl delete <udid>` for one device.
    case device(name: String, udid: String, approximateBytes: Int64?)
    /// `simctl runtime delete <identifier>` for one runtime.
    case runtime(name: String, identifier: String, approximateBytes: Int64?)

    /// The dialog title.
    public var title: String {
        switch self {
        case .command(let title, _): "\(title)?"
        case .device(let name, _, _): "Delete “\(name)”?"
        case .runtime(let name, _, _): "Delete the \(name) runtime?"
        }
    }

    /// The confirming button: "Run" or "Delete".
    public var buttonTitle: String {
        switch self {
        case .command: "Run"
        case .device, .runtime: "Delete"
        }
    }

    /// The dialog message: what is removed, the command that runs, and whether it can be undone.
    public var message: String {
        switch self {
        case .command(_, let commandText):
            return "TruongCleaner will run:\n\(commandText)\n\n"
                + "The tool removes the items itself, so they cannot be put back from the Trash."
        case .device(_, let udid, let bytes):
            return "Deletes this simulator with its apps and data" + Self.sizePhrase(bytes)
                + ". TruongCleaner will run:\n/usr/bin/xcrun simctl delete \(udid)\n\n"
                + "It cannot be put back."
        case .runtime(let name, let identifier, let bytes):
            return "Deletes the simulator runtime \(name)" + Self.sizePhrase(bytes)
                + ". TruongCleaner will run:\n/usr/bin/xcrun simctl runtime delete \(identifier)\n\n"
                + "Xcode can download it again."
        }
    }

    private static func sizePhrase(_ bytes: Int64?) -> String {
        bytes.map { ", about \(ByteFormatter.string($0))" } ?? ""
    }
}

extension OwnerCommandResult {
    /// The command's tool is not on this Mac.
    public var isToolMissing: Bool { skipped == "tool not found" }

    /// How the run ended, in one plain line: "Finished", "Failed (exit code 3)", "Timed out and was
    /// stopped", "Not installed" or "Not run: <reason>".
    public var summaryText: String {
        if let reason = skipped { return isToolMissing ? DeveloperRowState.notInstalledText : "Not run: \(reason)" }
        if timedOut { return "Timed out and was stopped" }
        guard let exitCode else { return "Stopped before it finished" }
        return exitCode == 0 ? "Finished" : "Failed (exit code \(exitCode))"
    }
}

extension OwnerCommandID {
    /// A short name for History, for example "Homebrew cleanup". An unknown ID shows its raw text.
    public var title: String {
        switch self {
        case .simctlDeleteUnavailable: "Delete unavailable simulators"
        case .brewCleanup: "Homebrew cleanup"
        case .pnpmStorePrune: "pnpm store prune"
        case .goCleanCache: "Go build cache"
        case .goCleanModcache: "Go module cache"
        case .dockerImagePrune: "Docker unused images"
        case .dockerBuilderPrune: "Docker build cache"
        case .simctlDeleteDevice: "Delete simulator"
        case .simctlDeleteRuntime: "Delete simulator runtime"
        default: rawValue
        }
    }
}
