import Foundation
import Synchronization
import Testing
@testable import CleanerScanner

/// The thread budget that all walks of one scan share (REQ-SCAN-06).
struct WorkerBudgetTests {
    @Test
    func lanesTakeThreadsUpToTheTotal() {
        let budget = WorkerBudget(total: 3)

        #expect(budget.tryStartLane())
        #expect(budget.tryStartLane())
        #expect(budget.tryStartLane())
        #expect(budget.tryStartLane() == false)
        #expect(budget.used == 3)

        budget.endLane()
        #expect(budget.used == 2)
        #expect(budget.tryStartLane())
    }

    @Test
    func extraThreadsNeedARoomAndStayOutOfTheWayOfWaitingLanes() {
        let budget = WorkerBudget(total: 4)
        #expect(budget.tryStartLane())
        budget.setIdleLanes(2)

        // 1 in use + 2 kept for lanes that have not started: one thread is free for an extra.
        #expect(budget.tryAcquireExtra())
        #expect(budget.tryAcquireExtra() == false)
        // The waiting lanes still find their threads.
        #expect(budget.tryStartLane())
        #expect(budget.tryStartLane())
        #expect(budget.tryStartLane() == false)
        #expect(budget.used == 4)
    }

    @Test
    func withNoLaneWaitingAnExtraMayTakeEveryFreeThread() {
        let budget = WorkerBudget(total: 3)
        #expect(budget.tryStartLane())
        budget.setIdleLanes(0)

        #expect(budget.tryAcquireExtra())
        #expect(budget.tryAcquireExtra())
        #expect(budget.tryAcquireExtra() == false)
        budget.releaseExtra()
        #expect(budget.tryAcquireExtra())
    }

    @Test
    func theRoomHintFollowsTheCounts() {
        let budget = WorkerBudget(total: 2)
        #expect(budget.mightHaveRoom)
        #expect(budget.tryStartLane())
        #expect(budget.mightHaveRoom)
        #expect(budget.tryAcquireExtra())
        #expect(budget.mightHaveRoom == false)
        budget.releaseExtra()
        #expect(budget.mightHaveRoom)
    }

    @Test
    func countsNeverGoBelowZero() {
        let budget = WorkerBudget(total: 2)
        budget.endLane()
        budget.releaseExtra()
        #expect(budget.used == 0)
    }

    // MARK: Walks that use the budget

    @Test
    func aWalkWithABudgetFindsTheSameTotalsAndGivesEveryThreadBack() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        for index in 0..<40 {
            try fixture.file("Wide/d\(index)/a/b/one.bin", pages: 1)
            try fixture.file("Wide/d\(index)/a/two.bin", pages: 2)
        }
        let root = fixture.url("Wide")
        let fixed = try await BulkWalker.walk(root, options: WalkOptions(maxWorkers: 1, totalsDepth: 2))

        let budget = WorkerBudget(total: 6)
        #expect(budget.tryStartLane())
        var options = WalkOptions(maxWorkers: 6, totalsDepth: 2)
        options.budget = budget
        let shared = try await BulkWalker.walk(root, options: options)

        // Only the walk's own thread is still counted; every extra thread was given back.
        #expect(budget.used == 1)
        #expect(shared.files == fixed.files)
        #expect(shared.directories == fixed.directories)
        #expect(shared.nodes.count == fixed.nodes.count)
        #expect(shared.nodes.first?.allocatedBytes == fixed.nodes.first?.allocatedBytes)
        #expect(shared.nodes.first?.privateBytes == fixed.nodes.first?.privateBytes)
        #expect(shared.nodes.first?.fileCount == fixed.nodes.first?.fileCount)
        #expect(shared.partial == false)
        budget.endLane()
        #expect(budget.used == 0)
    }

    @Test
    func aWalkNeverHoldsMoreThreadsThanTheBudgetHas() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        for index in 0..<60 {
            try fixture.file("Wide/d\(index)/e/f/g.bin", pages: 1)
        }
        let budget = WorkerBudget(total: 2)
        #expect(budget.tryStartLane())
        var options = WalkOptions(maxWorkers: 8, totalsDepth: 1)
        options.budget = budget

        let finished = Mutex(false)
        let sampler = Task.detached { () -> Int in
            var peak = 0
            while !finished.withLock({ $0 }) {
                peak = max(peak, budget.used)
                try? await Task.sleep(for: .milliseconds(1))
            }
            return peak
        }
        let result = try await BulkWalker.walk(fixture.url("Wide"), options: options)
        finished.withLock { $0 = true }
        let peak = await sampler.value

        #expect(peak <= 2)
        #expect(result.files == 60)
        #expect(budget.used == 1)
    }
}
