import Foundation
import Synchronization

/// Counts the walker threads of all walks that run at the same time in one scan, so that together they
/// never exceed `total` (REQ-SCAN-06).
///
/// Every walk in flight (a "lane") holds one thread from the moment the scan engine starts it. A walk
/// that finds more directories than it has threads for may take extra threads while the budget has
/// room, so a large folder uses the threads that small folders leave free. Extra threads are given back
/// when the walk ends.
///
/// The engine also tells the budget how many lanes are waiting to start (`setIdleLanes`). Extra threads
/// leave that many threads free, so a walk that is still to start always finds a thread.
final class WorkerBudget: Sendable {
    private struct State {
        var used = 0
        var idleLanes = 0
    }

    /// Most threads that exist at once.
    let total: Int
    private let state = Mutex(State())
    /// `total - used - idleLanes` as of the last change. Lets a walker skip the lock when nothing is free.
    private let room: Atomic<Int>

    init(total: Int) {
        self.total = max(1, total)
        self.room = Atomic(max(1, total))
    }

    /// False when no extra thread is free, as of the last change. A true answer may be stale: ask
    /// `tryAcquireExtra` before relying on it.
    var mightHaveRoom: Bool { room.load(ordering: .relaxed) > 0 }

    private func publish(_ state: State) {
        room.store(total - state.used - state.idleLanes, ordering: .relaxed)
    }

    /// Threads in use right now. For tests.
    var used: Int { state.withLock { $0.used } }

    /// Takes the first thread of a new walk. False when every thread is taken.
    func tryStartLane() -> Bool {
        state.withLock { state in
            guard state.used < total else { return false }
            state.used += 1
            publish(state)
            return true
        }
    }

    /// Gives back the first thread of a walk that has ended.
    func endLane() {
        state.withLock { state in
            state.used = max(0, state.used - 1)
            publish(state)
        }
    }

    /// Sets how many lanes may still start. Extra threads stay out of their way.
    ///
    /// This replaces the value for every user of the budget. A budget shared by several scans uses
    /// ``adjustIdleLanes(by:)`` instead, so that each scan only changes its own share.
    func setIdleLanes(_ count: Int) {
        state.withLock { state in
            state.idleLanes = max(0, count)
            publish(state)
        }
    }

    /// Changes the number of idle lanes by `delta`, so several users of one budget each keep their own share.
    func adjustIdleLanes(by delta: Int) {
        state.withLock { state in
            state.idleLanes = max(0, state.idleLanes + delta)
            publish(state)
        }
    }

    /// Takes one more thread for a walk that has work to hand out. False when none is free.
    func tryAcquireExtra() -> Bool {
        state.withLock { state in
            guard state.used + state.idleLanes < total else { return false }
            state.used += 1
            publish(state)
            return true
        }
    }

    /// Gives back an extra thread when it ends.
    func releaseExtra() {
        state.withLock { state in
            state.used = max(0, state.used - 1)
            publish(state)
        }
    }
}

extension WorkerBudget {
    /// Most walker threads the whole process may have at once: `min(6, activeProcessorCount)`.
    ///
    /// Six, not eight (task 2.7, `docs/EVIDENCE.md`): more threads wait on each other inside APFS.
    static let processWideTotal = ScanRun.Limits.threadBudget(cores: ProcessInfo.processInfo.activeProcessorCount)

    /// The one budget every entry point shares (Smart Clean, categories, Large Files, app sizes and
    /// leftovers), so that together they never run more than ``processWideTotal`` walker threads.
    static let shared = WorkerBudget(total: processWideTotal)

    /// The budget entry points use: ``shared`` unless a test installs its own with
    /// `WorkerBudget.$current.withValue(_:operation:)`. A task-local, so a test's budget reaches the
    /// walks it starts and no other test.
    @TaskLocal static var current: WorkerBudget = .shared

    /// Waits until a first thread is free and takes it as a new lane. False when the task was cancelled
    /// first; then nothing was taken.
    ///
    /// Waiting only happens while another walk holds the budget, so it never polls while the app is idle.
    func acquireLane() async -> Bool {
        var delay = Duration.milliseconds(2)
        while !tryStartLane() {
            if Task.isCancelled { return false }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return false
            }
            delay = min(delay * 2, .milliseconds(25))
        }
        return true
    }
}

/// Runs a walk on a lane of the process-wide budget. Used by every entry point except the scan engine,
/// which manages its lanes itself.
enum SharedBudgetWalk {
    /// Walks `root` once a thread of ``WorkerBudget/current`` is free; the walk may grow into more threads
    /// while the budget has room, up to `options.maxWorkers`.
    ///
    /// - Throws: `CancellationError` if the calling task was cancelled while waiting for a thread,
    ///   otherwise what ``BulkWalker/walk(_:options:progress:)`` throws.
    static func walk(
        _ root: URL, options: WalkOptions, progress: (@Sendable (WalkProgress) -> Void)? = nil
    ) async throws -> WalkResult {
        let budget = WorkerBudget.current
        guard await budget.acquireLane() else { throw CancellationError() }
        defer { budget.endLane() }
        var shared = options
        shared.budget = budget
        return try await BulkWalker.walk(root, options: shared, progress: progress)
    }
}
