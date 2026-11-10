import CleanerCore
import CleanerTestSupport
import Foundation
import Synchronization
import Testing
@testable import CleanerScanner

/// Scanner review #7: one walker budget for the whole process. Every entry point takes its threads from
/// `WorkerBudget.current` (the process-wide `shared` one unless a test installs its own), so Smart Clean,
/// the category scan, Large Files and app sizing together never exceed `min(6, cores)` threads.
struct SharedBudgetTests {
    /// The public ways to start a walk.
    enum EntryPoint: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case largeFiles, categories, appSize, scanEngine

        var testDescription: String { rawValue }
    }

    @Test func theProcessWideBudgetIsSixOrTheCoreCount() {
        let expected = min(6, ProcessInfo.processInfo.activeProcessorCount)
        #expect(WorkerBudget.shared.total == expected)
        #expect(WorkerBudget.processWideTotal == expected)
        #expect(WorkerBudget.current === WorkerBudget.shared)
    }

    @Test func walkOptionsNeverAskForMoreThanTheProcessBudget() {
        #expect(WalkOptions().maxWorkers <= 6)
    }

    private func fixture() throws -> EngineFixture {
        let fixture = try EngineFixture()
        try fixture.file("Library/Caches/com.example.One/a", pages: 4)
        try fixture.file("Documents/d.bin", pages: 3)
        return fixture
    }

    /// Runs one entry point to the end and reports whether it found what the fixture holds.
    private func run(_ entry: EntryPoint, on fixture: EngineFixture) async -> Bool {
        switch entry {
        case .largeFiles:
            let query = LargeFileQuery(roots: [fixture.home], minBytes: fixture.bytes(3), limit: 10)
            let found = try? await LargeFileFinder.find(query)
            return found?.count == 2
        case .categories:
            let totals = await CategoryScanner.measure(home: fixture.home, applicationsRoot: nil, usersRoot: nil)
            return totals.bytes(of: .libraryCaches) == fixture.bytes(4) && totals.bytes(of: .documents) == fixture.bytes(3)
        case .appSize:
            let size = await AppSizer().size(of: fixture.url("Library/Caches"))
            return size.allocatedBytes == fixture.bytes(4) && !size.isPartial
        case .scanEngine:
            let rule = makeRule("test.caches", roots: [["Library", "Caches"]])
            let (_, report) = await fixture.scan([rule])
            return fixture.result("test.caches", in: report)?.measuredBytes == fixture.bytes(4) && !report.partial
        }
    }

    @Test(arguments: EntryPoint.allCases)
    func everyEntryPointWaitsForAThreadOfTheSharedBudget(entry: EntryPoint) async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let budget = WorkerBudget(total: 2)
        // Every thread is taken by someone else.
        #expect(budget.tryStartLane())
        #expect(budget.tryStartLane())

        let finished = Atomic<Bool>(false)
        let walk = WorkerBudget.$current.withValue(budget) {
            Task { () -> Bool in
                let ok = await run(entry, on: fixture)
                finished.store(true, ordering: .sequentiallyConsistent)
                return ok
            }
        }
        try await Task.sleep(for: .milliseconds(250))
        #expect(finished.load(ordering: .sequentiallyConsistent) == false, "\(entry) ran without a free thread")
        #expect(budget.used == 2)

        budget.endLane()
        budget.endLane()
        let ok = await walk.value
        #expect(ok, "\(entry) found the wrong data")
        #expect(budget.used == 0)
        #expect(budget.mightHaveRoom)
    }

    @Test func entryPointsRunningTogetherStayWithinOneBudget() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let budget = WorkerBudget(total: 3)
        let peak = Atomic<Int>(0)
        let sampling = Atomic<Bool>(true)
        let sampler = Task.detached {
            while sampling.load(ordering: .relaxed) {
                let used = budget.used
                var seen = peak.load(ordering: .relaxed)
                while used > seen {
                    let (exchanged, original) = peak.compareExchange(
                        expected: seen, desired: used, ordering: .relaxed)
                    if exchanged { break }
                    seen = original
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }

        let allCorrect = await WorkerBudget.$current.withValue(budget) {
            await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<3 {
                    for entry in EntryPoint.allCases {
                        group.addTask { await run(entry, on: fixture) }
                    }
                }
                var all = true
                for await ok in group where !ok { all = false }
                return all
            }
        }
        sampling.store(false, ordering: .relaxed)
        await sampler.value

        #expect(allCorrect)
        #expect(peak.load(ordering: .relaxed) <= 3)
        // Everything was given back, including the share of idle lanes a scan reserves.
        #expect(budget.used == 0)
        #expect(budget.mightHaveRoom)
    }

    @Test func aScanReservesAndReturnsOnlyItsOwnIdleLanes() {
        let budget = WorkerBudget(total: 4)
        budget.adjustIdleLanes(by: 2)  // one scan
        budget.adjustIdleLanes(by: 1)  // another scan
        #expect(budget.tryAcquireExtra())  // 4 - 3 reserved = 1 free
        #expect(!budget.tryAcquireExtra())
        budget.adjustIdleLanes(by: -2)  // the first scan ends
        #expect(budget.tryAcquireExtra())
        budget.releaseExtra()
        budget.releaseExtra()
        budget.adjustIdleLanes(by: -1)
        budget.adjustIdleLanes(by: -5)  // never below zero
        #expect(budget.mightHaveRoom)
        #expect(budget.used == 0)
    }

    @Test func aCancelledWaitForAThreadReturnsWithoutTakingOne() async throws {
        let budget = WorkerBudget(total: 1)
        #expect(budget.tryStartLane())
        let waiter = Task { await budget.acquireLane() }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        let got = await waiter.value
        #expect(got == false)
        #expect(budget.used == 1)
        budget.endLane()
    }
}
