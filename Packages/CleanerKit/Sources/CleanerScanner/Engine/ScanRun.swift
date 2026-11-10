import CleanerCore
import Foundation

/// One scan from start to report. Runs off the main actor and reads only.
///
/// Work is a bounded task group: at most `roots` child tasks exist at any time, each walking one root.
/// Everything else (resolving roots, merging, ordering, de-duplicating) happens in the single parent
/// task, so no state is shared between threads except the progress counters and the thread budget.
///
/// All walks together use at most `Limits.maxThreads` threads (and never more than the Mac has cores). Each walk in flight holds one
/// thread; a walk with more directories than threads takes free ones from the budget, so a large folder
/// is not limited to a fixed share (`WorkerBudget`).
enum ScanRun {
    /// How much parallelism a request gets after clamping.
    struct Limits: Equatable {
        /// Walks in flight at once.
        var roots: Int
        /// Most threads one walk may use.
        var workers: Int

        init(roots: Int, workers: Int) {
            self.roots = roots
            self.workers = workers
        }

        init(_ request: ScanRequest, cores: Int = ProcessInfo.processInfo.activeProcessorCount) {
            let budget = Self.threadBudget(cores: cores)
            roots = max(1, min(request.maxConcurrentRoots, budget))
            workers = max(1, min(request.workersPerRoot, budget))
        }

        /// Most threads all walks of one scan may use together (REQ-SCAN-06 allows `min(8, cores)`).
        ///
        /// Six, not eight. With `ATTR_CMNEXT_PRIVATESIZE` every file costs the kernel about 20 µs, and on
        /// a 14-core M3 Max the Smart Clean scan of a real home folder (1.1 M files in `~/Library/Caches`)
        /// took 6.5 s with 6 threads and 7.8 s with 8: the extra threads wait on each other inside APFS.
        /// 4 threads took 7.9 s and 5 took 6.8 s (task 2.7, `docs/EVIDENCE.md`).
        static let maxThreads = 6

        /// Threads all walks of one scan may use together on a Mac with `cores` cores.
        static func threadBudget(cores: Int) -> Int {
            max(1, min(maxThreads, cores))
        }
    }

    /// Which speed-ups are on. `standard` is what the app uses. `reference` is the plain engine, kept so
    /// that tests can prove the fast one finds the same things.
    struct Tuning: Sendable, Equatable {
        /// Walks share one thread budget and grow into free threads. Off: a fixed share per walk.
        var elasticWorkers = true
        /// A `.glob` rule does not open folders that cannot hold a match.
        var globDescent = true
        /// Roots with the most entries start first.
        var largestFirst = true
        /// A finished rule is delivered ahead of earlier rules when that cannot change the result.
        var deliverEarly = true

        static let standard = Tuning()
        static let reference = Tuning(
            elasticWorkers: false, globDescent: false, largestFirst: false, deliverEarly: false)
    }

    /// Progress is passed on at most this often.
    static let progressInterval = Duration.milliseconds(100)

    /// Runs the scan. Events go to `emit` in order, except `.progress`, which may come from walker threads.
    /// Does not emit `.finished`; the caller does that with the returned report.
    ///
    /// When the calling task is cancelled the walks stop within about 100 ms and the report is partial.
    @concurrent
    ///
    /// - Parameter sharedBudget: The thread budget to run on. `ScanEngine` passes the process-wide one, so a
    ///   scan and any other walk together stay within it. `nil` gives this scan a budget of its own.
    static func execute(
        _ request: ScanRequest, tuning: Tuning = .standard, cores: Int = ProcessInfo.processInfo.activeProcessorCount,
        sharedBudget: WorkerBudget? = nil,
        emit: @escaping @Sendable (ScanEvent) -> Void
    ) async -> ScanReport {
        let clock = ContinuousClock()
        let started = clock.now
        let limits = Limits(request, cores: cores)
        let threads = Limits.threadBudget(cores: cores)
        let budget = tuning.elasticWorkers ? (sharedBudget ?? WorkerBudget(total: threads)) : nil
        var idle = IdleLanes(budget: budget)
        let context = ScanContext(
            policy: PathPolicy(environment: request.environment, userExclusions: request.userExclusions),
            environment: request.environment,
            // Fixed share when the budget is off: the threads split evenly between the walks in flight.
            workers: budget == nil ? max(1, min(limits.workers, threads / limits.roots)) : limits.workers,
            budget: budget,
            globDescent: tuning.globDescent,
            progress: ProgressAggregator(interval: progressInterval) { files, bytes in
                emit(.progress(files: files, allocatedBytes: bytes))
            }
        )

        var plan = RunPlan(
            request: request, clock: clock, largestFirst: tuning.largestFirst, deliverEarly: tuning.deliverEarly,
            emit: emit)
        await withTaskGroup(of: (Int, RootOutcome).self) { group in
            var inFlight = 0
            while true {
                while inFlight < limits.roots, !Task.isCancelled, plan.hasQueuedUnits {
                    // The walk's first thread comes from the budget; the group never starts more walks
                    // than it has threads for.
                    if let budget, !budget.tryStartLane() { break }
                    guard let unit = plan.nextUnit() else {
                        budget?.endLane()
                        break
                    }
                    group.addTask {
                        (unit.ruleIndex, await RootScanner.scan(
                            rule: unit.rule, root: unit.root, slot: unit.slot, context: context))
                    }
                    inFlight += 1
                }
                // Walks still to start keep one thread each free; with none waiting, a walk may take them all.
                idle.set(plan.hasQueuedUnits ? limits.roots - inFlight : 0)
                plan.flush()
                guard inFlight > 0, let (ruleIndex, outcome) = await group.next() else {
                    // A budget shared with other walks can be full while none of ours runs. Wait for a
                    // thread instead of ending the scan with roots unwalked.
                    if inFlight == 0, budget != nil, plan.hasQueuedUnits, !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(10))
                        continue
                    }
                    break
                }
                inFlight -= 1
                // Reserve first, then free the walk's thread, so that nothing else takes it in between.
                idle.set(plan.hasQueuedUnits ? limits.roots - inFlight : 0)
                budget?.endLane()
                plan.absorb(outcome, forRule: ruleIndex)
            }
        }
        idle.set(0)
        plan.abandonUnfinished()
        plan.flush()

        let results = plan.results
        return ScanReport(
            results: results,
            partial: Task.isCancelled || results.contains { $0.partial },
            duration: started.duration(to: clock.now),
            duplicatesDropped: plan.duplicatesDropped
        )
    }
}

/// A scan's share of the idle lanes of a budget it may share with other scans. It only ever changes its own
/// share, and gives it back with `set(0)`.
private struct IdleLanes {
    let budget: WorkerBudget?
    private var count = 0

    init(budget: WorkerBudget?) {
        self.budget = budget
    }

    mutating func set(_ value: Int) {
        let target = max(0, value)
        guard target != count else { return }
        budget?.adjustIdleLanes(by: target - count)
        count = target
    }
}
