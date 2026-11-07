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
    func setIdleLanes(_ count: Int) {
        state.withLock { state in
            state.idleLanes = max(0, count)
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
