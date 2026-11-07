import Darwin
import Foundation
import Synchronization

/// How a supervised process ended.
package struct SupervisedOutcome: Sendable {
    /// Exit status or signal number once the process had ended; `nil` while it was still running when we gave up.
    package var terminationStatus: Int32?
    /// `true` when the process ended by calling `exit` (not by a signal).
    package var exitedNormally: Bool
    /// `true` when the process ran past its timeout and was stopped.
    package var timedOut: Bool
    /// Set when the process could not be started.
    package var launchError: String?
    /// Standard output. With `mergeOutput`, standard error is in here too.
    package var stdout: Data
    /// Standard error. Empty with `mergeOutput`.
    package var stderr: Data
}

/// Runs a child process and waits for it without holding a thread.
///
/// Output is read through dispatch read sources, the exit comes from the process's termination
/// handler, and the timeout is a delayed work item. The caller awaits a continuation, so no
/// cooperative-pool thread and no dispatch thread is parked for the life of the child. A burst of
/// commands therefore costs no more threads than a single one.
///
/// Callers decide what is allowed to run. This type does no checking of its own: ``ReadOnlyCommand``
/// applies its allow-list before calling it, and `CleanerActions.OwnerProcess` applies the catalog's
/// fixed commands. The file is named after `ReadOnlyCommand` because it is the launcher beneath it,
/// and `scripts/check-deletion-sites.sh` allows process launching only there and in `CleanerActions`.
package enum SupervisedProcess {
    /// How long to keep waiting for the output to end after the process has exited. A grandchild that
    /// inherited the pipe must not hold the caller up.
    static let drainGrace: DispatchTimeInterval = .seconds(5)

    /// How long to wait for the exit after `SIGKILL` before giving up.
    static let killWait: DispatchTimeInterval = .seconds(2)

    /// Launches `executable` with no shell, standard input from `/dev/null` and the given environment.
    ///
    /// - Parameters:
    ///   - timeout: How long the process may run before it is sent `SIGTERM`.
    ///   - terminateGrace: How long it may take to end after `SIGTERM` before it is sent `SIGKILL`.
    ///   - mergeOutput: Send standard error into the same stream as standard output.
    ///   - keepLast: When set, only about the last `keepLast` bytes of each stream are kept in memory.
    /// - Returns: How it ended. Never throws; a launch failure is in `launchError`.
    package static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        timeout: Duration,
        terminateGrace: Duration,
        mergeOutput: Bool,
        keepLast: Int? = nil
    ) async -> SupervisedOutcome {
        await withCheckedContinuation { continuation in
            let run = Run(
                executable, arguments, environment: environment, timeout: timeout,
                terminateGrace: terminateGrace, mergeOutput: mergeOutput, keepLast: keepLast)
            run.start(continuation)
        }
    }

    static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let parts = duration.components
        let nanoseconds = Double(parts.seconds) * 1e9 + Double(parts.attoseconds) / 1e9
        guard nanoseconds > 0 else { return .nanoseconds(0) }
        return .nanoseconds(Int(min(nanoseconds, Double(Int.max / 2))))
    }

    /// A delayed work item. `DispatchWorkItem` is thread-safe to cancel but is not marked `Sendable`.
    private struct DelayedItem: @unchecked Sendable {
        let item: DispatchWorkItem
    }

    /// One launched process. All mutable state is behind `state`.
    private final class Run: Sendable {
        private struct State {
            var stdout = Data()
            var stderr = Data()
            var stdoutOpen = true
            var stderrOpen = true
            var exited = false
            var timedOut = false
            var finished = false
            var continuation: CheckedContinuation<SupervisedOutcome, Never>?
            var timers: [DelayedItem] = []
        }

        private let process = Process()
        private let outPipe = Pipe()
        private let errPipe: Pipe?
        private let state = Mutex(State())
        private let timeout: Duration
        private let terminateGrace: Duration
        private let keepLast: Int?
        private let queue = DispatchQueue(label: "TruongCleaner.SupervisedProcess", qos: .userInitiated)

        init(
            _ executable: String, _ arguments: [String], environment: [String: String],
            timeout: Duration, terminateGrace: Duration, mergeOutput: Bool, keepLast: Int?
        ) {
            self.timeout = timeout
            self.terminateGrace = terminateGrace
            self.keepLast = keepLast
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outPipe
            if mergeOutput {
                errPipe = nil
                process.standardError = outPipe
            } else {
                let pipe = Pipe()
                errPipe = pipe
                process.standardError = pipe
            }
        }

        func start(_ continuation: CheckedContinuation<SupervisedOutcome, Never>) {
            state.withLock { $0.continuation = continuation }
            if errPipe == nil { state.withLock { $0.stderrOpen = false } }

            process.terminationHandler = { [self] _ in processEnded() }
            outPipe.fileHandleForReading.readabilityHandler = { [self] handle in
                received(handle.availableData, isStdout: true, from: handle)
            }
            errPipe?.fileHandleForReading.readabilityHandler = { [self] handle in
                received(handle.availableData, isStdout: false, from: handle)
            }
            do {
                try process.run()
            } catch {
                finish(launchError: error.localizedDescription)
                return
            }
            schedule(after: SupervisedProcess.dispatchInterval(timeout)) { [self] in timeOut() }
        }

        // MARK: Events

        private func received(_ data: Data, isStdout: Bool, from handle: FileHandle) {
            if data.isEmpty {
                // End of stream. Stop watching so the source does not spin on EOF.
                handle.readabilityHandler = nil
                state.withLock { state in
                    if isStdout { state.stdoutOpen = false } else { state.stderrOpen = false }
                }
                finishIfDone()
                return
            }
            let keepLast = keepLast
            state.withLock { state in
                if isStdout {
                    Self.append(data, to: &state.stdout, keepLast: keepLast)
                } else {
                    Self.append(data, to: &state.stderr, keepLast: keepLast)
                }
            }
        }

        private static func append(_ chunk: Data, to buffer: inout Data, keepLast: Int?) {
            buffer.append(chunk)
            if let keepLast, buffer.count > keepLast * 2 { buffer = Data(buffer.suffix(keepLast)) }
        }

        private func processEnded() {
            state.withLock { $0.exited = true }
            // A grandchild that kept the pipe open must not hold us up for long.
            schedule(after: SupervisedProcess.drainGrace) { [self] in finish(launchError: nil) }
            finishIfDone()
        }

        private func timeOut() {
            let running = state.withLock { state -> Bool in
                guard !state.exited, !state.finished else { return false }
                state.timedOut = true
                return true
            }
            guard running else { return }
            process.terminate()
            schedule(after: SupervisedProcess.dispatchInterval(terminateGrace)) { [self] in
                guard !state.withLock({ $0.exited || $0.finished }) else { return }
                kill(process.processIdentifier, SIGKILL)
                schedule(after: SupervisedProcess.killWait) { [self] in finish(launchError: nil) }
            }
        }

        private func finishIfDone() {
            let done = state.withLock { $0.exited && !$0.stdoutOpen && !$0.stderrOpen }
            if done { finish(launchError: nil) }
        }

        // MARK: Finishing

        private func schedule(after interval: DispatchTimeInterval, _ body: @escaping @Sendable () -> Void) {
            let item = DispatchWorkItem(block: body)
            let accepted = state.withLock { state -> Bool in
                guard !state.finished else { return false }
                state.timers.append(DelayedItem(item: item))
                return true
            }
            if accepted { queue.asyncAfter(deadline: .now() + interval, execute: item) }
        }

        /// Ends the run once: stops watching, drops the handlers that point back at this object, resumes the caller.
        /// The pipes close when this object is released; closing a handle a read source is using would raise.
        private func finish(launchError: String?) {
            let first = state.withLock { state -> Bool in
                guard !state.finished else { return false }
                state.finished = true
                return true
            }
            guard first else { return }
            let timers = state.withLock { state -> [DelayedItem] in
                let taken = state.timers
                state.timers = []
                return taken
            }
            let continuation = state.withLock { state -> CheckedContinuation<SupervisedOutcome, Never>? in
                let taken = state.continuation
                state.continuation = nil
                return taken
            }
            let (timedOut, stdout, stderr) = state.withLock { ($0.timedOut, $0.stdout, $0.stderr) }
            var outcome = SupervisedOutcome(
                terminationStatus: nil, exitedNormally: false, timedOut: timedOut,
                launchError: launchError, stdout: stdout, stderr: stderr)
            for timer in timers { timer.item.cancel() }
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe?.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            if launchError == nil, !process.isRunning {
                outcome.terminationStatus = process.terminationStatus
                outcome.exitedNormally = process.terminationReason == .exit
            }
            continuation?.resume(returning: outcome)
        }
    }
}
