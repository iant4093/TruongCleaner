import Darwin
import Foundation
import Synchronization
import os

/// An open directory waiting to be walked, with what a worker needs to carry on from it.
struct WalkJob: Sendable {
    /// Open descriptor of the directory. The receiver closes it.
    var fd: Int32
    /// Absolute path as NUL-terminated bytes (exact, not decoded).
    var path: [CChar]
    /// 0 for the root.
    var depth: Int
    /// Kept node that receives this directory's totals (itself when kept, else its nearest kept ancestor).
    var keptNode: Int
    /// Whether this directory is, or lies below, a pruned folder (`WalkOptions.pruneNames`).
    var prune: PruneState = .none
    /// Where this directory is inside the rule's glob (`WalkOptions.descent`).
    var descent: DescentCursor = .everything
}

/// Queue of open directories shared by the workers.
///
/// `pending` counts queued plus in-flight jobs, so a worker knows when the whole walk is over.
/// `@unchecked Sendable`: every access to the mutable state is under `condition`.
final class JobQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var items: [WalkJob] = []
    private var pending = 0
    private var stopped = false

    func push(_ job: WalkJob) {
        condition.lock()
        items.append(job)
        pending += 1
        condition.signal()
        condition.unlock()
    }

    /// Hands a directory to other workers only while fewer than `limit` are waiting. This bounds open descriptors.
    /// Returns false (and keeps nothing) when the queue is full or stopped.
    func pushIfBelow(_ job: WalkJob, limit: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard items.count < limit, !stopped else { return false }
        items.append(job)
        pending += 1
        condition.signal()
        return true
    }

    /// Blocks until a directory is available. Returns nil when the walk is finished or stopped.
    func pop() -> WalkJob? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if stopped { return nil }
            if let job = items.popLast() { return job }
            if pending == 0 { return nil }
            condition.wait()
        }
    }

    /// Marks one job (queued or in flight) as finished.
    func done() {
        condition.lock()
        pending -= 1
        if pending == 0 { condition.broadcast() }
        condition.unlock()
    }

    /// Wakes every waiting worker and makes `pop` return nil.
    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }

    /// Takes whatever is still queued so the caller can close the descriptors.
    func drain() -> [WalkJob] {
        condition.lock()
        defer { condition.unlock() }
        let rest = items
        items.removeAll()
        return rest
    }
}

/// Monotonic nanoseconds. Not affected by clock changes or sleep.
func monotonicNanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
}

/// Converts a duration to nanoseconds, never negative, saturating instead of overflowing.
func nanoseconds(of duration: Duration) -> UInt64 {
    let parts = duration.components
    guard parts.seconds > 0 || (parts.seconds == 0 && parts.attoseconds > 0) else { return 0 }
    let (wholeNanos, overflow) = UInt64(parts.seconds).multipliedReportingOverflow(by: 1_000_000_000)
    if overflow { return .max }
    let (sum, addOverflow) = wholeNanos.addingReportingOverflow(UInt64(parts.attoseconds / 1_000_000_000))
    return addOverflow ? .max : sum
}

/// Cancellation flag plus optional deadline, shared by all workers.
final class StopControl: Sendable {
    private let flag = Atomic<Bool>(false)
    private let incompleteFlag = Atomic<Bool>(false)
    private let deadline: UInt64?

    init(limit: Duration?) {
        if let limit {
            let (sum, overflow) = monotonicNanoseconds().addingReportingOverflow(nanoseconds(of: limit))
            deadline = overflow ? .max : sum
        } else {
            deadline = nil
        }
    }

    /// Called from the task cancellation handler.
    func cancel() {
        flag.store(true, ordering: .relaxed)
    }

    /// True when workers must stop. Cheap enough to call once per directory and per batch.
    func check() -> Bool {
        if flag.load(ordering: .relaxed) { return true }
        if let deadline, monotonicNanoseconds() >= deadline {
            flag.store(true, ordering: .relaxed)
            return true
        }
        return false
    }

    /// Records that some work was skipped because of a stop.
    func markIncomplete() {
        incompleteFlag.store(true, ordering: .relaxed)
    }

    /// True when a stop caused work to be skipped.
    var isIncomplete: Bool { incompleteFlag.load(ordering: .relaxed) }
}

/// Throttled progress. At most one callback runs at a time, and never faster than the interval.
final class ProgressReporter: Sendable {
    private let callback: (@Sendable (WalkProgress) -> Void)?
    private let intervalNanos: UInt64
    private let nextDue = Atomic<UInt64>(0)
    private let files = Atomic<Int>(0)
    private let bytes = Atomic<Int64>(0)
    private let gate = OSAllocatedUnfairLock()

    init(interval: Duration, callback: (@Sendable (WalkProgress) -> Void)?) {
        self.callback = callback
        self.intervalNanos = nanoseconds(of: interval)
    }

    /// Adds what a worker just counted.
    func add(files fileDelta: Int, bytes byteDelta: Int64) {
        guard callback != nil, fileDelta != 0 || byteDelta != 0 else { return }
        files.add(fileDelta, ordering: .relaxed)
        bytes.add(byteDelta, ordering: .relaxed)
    }

    /// Emits a snapshot if one is due. `path` is turned into a URL only when a snapshot is emitted.
    /// The first call after the start always emits.
    func tick(path: [CChar]) {
        guard let callback else { return }
        let now = monotonicNanoseconds()
        let due = nextDue.load(ordering: .relaxed)
        guard now >= due else { return }
        // Only one worker wins the right to emit for this interval.
        let (exchanged, _) = nextDue.compareExchange(
            expected: due, desired: now &+ intervalNanos, ordering: .relaxed)
        guard exchanged else { return }
        // If the previous callback is still running, skip instead of waiting.
        _ = gate.withLockIfAvailable {
            callback(
                WalkProgress(
                    files: files.load(ordering: .relaxed), allocatedBytes: bytes.load(ordering: .relaxed),
                    currentPath: makeURL(fromPath: path, isDirectory: true)))
        }
    }
}

/// The worker threads of one walk.
///
/// Threads, not tasks: the work is blocking system calls, and the number of workers must be exact. The
/// caller is never blocked; it awaits a continuation that `onFinished` resumes on the last thread to end.
///
/// A walk with a `WorkerBudget` starts with the threads it is given and may add more while it runs
/// (`offerExtraWorker`), up to `maxThreads` in all and only while the budget has room. A walk without a
/// budget keeps exactly the threads it started with.
final class WalkGroup: Sendable {
    private struct State {
        var outputs: [WorkerOutput] = []
        var active = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let budget: WorkerBudget?
    private let maxThreads: Int
    private let body: @Sendable () -> WorkerOutput
    private let onFinished: @Sendable ([WorkerOutput]) -> Void

    /// - Parameters:
    ///   - budget: Thread budget shared with other walks, or nil for a fixed set of threads.
    ///   - maxThreads: Most threads this walk may have at once.
    ///   - body: One worker's work. Runs on its own thread.
    ///   - onFinished: Called once, on the last thread to end, with every worker's output.
    init(
        budget: WorkerBudget?,
        maxThreads: Int,
        body: @escaping @Sendable () -> WorkerOutput,
        onFinished: @escaping @Sendable ([WorkerOutput]) -> Void
    ) {
        self.budget = budget
        self.maxThreads = max(1, maxThreads)
        self.body = body
        self.onFinished = onFinished
    }

    /// Starts the first `count` threads. Call once.
    func start(workers count: Int) {
        let count = max(1, count)
        state.withLock { $0.active = count }
        for _ in 0..<count { launch(releasesBudget: false) }
    }

    /// Adds a thread if the budget has room and the walk is below its cap. Called by a running worker
    /// right after it put a directory in the queue, so the new thread has something to take.
    func offerExtraWorker() {
        guard let budget, budget.mightHaveRoom, budget.tryAcquireExtra() else { return }
        let added = state.withLock { state -> Bool in
            // Only a running worker calls this, so `active > 0`: the walk cannot have finished.
            guard state.active > 0, state.active < maxThreads else { return false }
            state.active += 1
            return true
        }
        if added {
            launch(releasesBudget: true)
        } else {
            budget.releaseExtra()
        }
    }

    private func launch(releasesBudget: Bool) {
        let thread = Thread { [self] in
            let output = body()
            if releasesBudget { budget?.releaseExtra() }
            let finished = state.withLock { state -> [WorkerOutput]? in
                state.outputs.append(output)
                state.active -= 1
                return state.active == 0 ? state.outputs : nil
            }
            if let finished { onFinished(finished) }
        }
        thread.stackSize = 1 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}

/// Lets a worker ask its walk for another thread without the context knowing the walk's thread group.
final class ExtraWorkers: Sendable {
    private let group = OSAllocatedUnfairLock<WalkGroup?>(initialState: nil)

    /// Connects the walk's thread group. Pass nil when the walk ends, which also breaks the reference cycle.
    func install(_ walkGroup: WalkGroup?) {
        group.withLock { $0 = walkGroup }
    }

    /// Asks for one more thread. Does nothing when no group is installed or the budget is full.
    func offer() {
        let current = group.withLock { $0 }
        current?.offerExtraWorker()
    }
}

/// Raises the soft open-file limit to at least 4,096 once per process, so deep trees times many workers do not hit 256.
enum FileLimit {
    private static let raised: Void = {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < 4096 else { return }
        // macOS rejects values above kern.maxfilesperproc (10,240 by default) even when rlim_max is "infinity".
        limit.rlim_cur = min(10_240, limit.rlim_max)
        setrlimit(RLIMIT_NOFILE, &limit)
    }()

    static func ensureMinimum() {
        _ = raised
    }
}

/// Builds a URL from exact NUL-terminated path bytes, without decoding them as text.
func makeURL(fromPath path: [CChar], isDirectory: Bool) -> URL {
    path.withUnsafeBufferPointer { buffer -> URL in
        guard let base = buffer.baseAddress else { return URL(filePath: "/") }
        return URL(fileURLWithFileSystemRepresentation: base, isDirectory: isDirectory, relativeTo: nil)
    }
}
