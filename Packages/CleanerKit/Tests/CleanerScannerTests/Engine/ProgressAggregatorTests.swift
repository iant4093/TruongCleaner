import Foundation
import Synchronization
import Testing
@testable import CleanerScanner

struct ProgressAggregatorTests {
    /// A clock the test moves by hand.
    private final class FakeClock: Sendable {
        private let time = Mutex(Duration.zero)
        func advance(_ amount: Duration) { time.withLock { $0 += amount } }
        func now() -> Duration { time.withLock { $0 } }
    }

    private final class Sink: Sendable {
        private let received = Mutex<[(files: Int, bytes: Int64)]>([])
        func record(_ files: Int, _ bytes: Int64) { received.withLock { $0.append((files, bytes)) } }
        var values: [(files: Int, bytes: Int64)] { received.withLock { $0 } }
    }

    @Test
    func reportsAtMostOncePerInterval() {
        let clock = FakeClock()
        let sink = Sink()
        let aggregator = ProgressAggregator(interval: .milliseconds(100), now: { clock.now() }, sink: sink.record)

        // One simulated second of updates every millisecond: at most 10 reports, plus the first.
        for step in 0..<1_000 {
            aggregator.update(slot: 0, files: step, bytes: Int64(step) * 10)
            clock.advance(.milliseconds(1))
        }
        #expect(sink.values.count >= 10)
        #expect(sink.values.count <= 11)
        #expect(sink.values.first?.files == 0)
    }

    @Test
    func sumsRunningAndFinishedWalks() {
        let clock = FakeClock()
        let sink = Sink()
        let aggregator = ProgressAggregator(interval: .milliseconds(100), now: { clock.now() }, sink: sink.record)

        aggregator.update(slot: 1, files: 10, bytes: 100)  // emits: 10 / 100
        aggregator.finish(slot: 1, files: 12, bytes: 120)
        clock.advance(.milliseconds(150))
        aggregator.update(slot: 2, files: 5, bytes: 50)  // 12 + 5
        clock.advance(.milliseconds(150))
        aggregator.update(slot: 2, files: 7, bytes: 70)  // the slot replaces its earlier counts

        #expect(sink.values.map(\.files) == [10, 17, 19])
        #expect(sink.values.map(\.bytes) == [100, 170, 190])
    }
}
