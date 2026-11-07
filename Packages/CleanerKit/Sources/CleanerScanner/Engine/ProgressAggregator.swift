import Foundation
import Synchronization

/// Sums the progress of several walks and passes the total on at most once per `interval`.
///
/// The walkers call `update` from their worker threads. The lock covers the bookkeeping only;
/// `sink` runs outside it.
final class ProgressAggregator: Sendable {
    private struct Slot {
        var files = 0
        var bytes: Int64 = 0
    }

    private struct State {
        var slots: [Int: Slot] = [:]
        var finished = Slot()
        var lastEmit: Duration?

        var total: (files: Int, bytes: Int64) {
            var files = finished.files
            var bytes = finished.bytes
            for slot in slots.values {
                files += slot.files
                bytes += slot.bytes
            }
            return (files, bytes)
        }
    }

    private let state = Mutex(State())
    private let interval: Duration
    private let now: @Sendable () -> Duration
    private let sink: @Sendable (Int, Int64) -> Void

    /// - Parameters:
    ///   - interval: Smallest time between two calls to `sink`.
    ///   - now: Monotonic time since some fixed origin. Tests pass a fake.
    ///   - sink: Receives total files and total allocated bytes.
    init(
        interval: Duration,
        now: @escaping @Sendable () -> Duration = ProgressAggregator.monotonicNow,
        sink: @escaping @Sendable (Int, Int64) -> Void
    ) {
        self.interval = interval
        self.now = now
        self.sink = sink
    }

    /// Time since the first call, from a continuous clock.
    static let monotonicNow: @Sendable () -> Duration = {
        let clock = ContinuousClock()
        let origin = clock.now
        return { origin.duration(to: clock.now) }
    }()

    /// Records the cumulative counts of one running walk and reports the total if the interval has passed.
    func update(slot: Int, files: Int, bytes: Int64) {
        let moment = now()
        let totals: (files: Int, bytes: Int64)? = state.withLock { state in
            state.slots[slot] = Slot(files: files, bytes: bytes)
            if let last = state.lastEmit, moment - last < interval { return nil }
            state.lastEmit = moment
            return state.total
        }
        if let totals { sink(totals.files, totals.bytes) }
    }

    /// Replaces a walk's running counts with its final counts. Does not report.
    func finish(slot: Int, files: Int, bytes: Int64) {
        state.withLock { state in
            state.slots[slot] = nil
            state.finished.files += files
            state.finished.bytes += bytes
        }
    }
}
