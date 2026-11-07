import CleanerCore
import Foundation

/// One scan from start to report. Runs off the main actor and reads only.
///
/// Work is a bounded task group: at most `roots` child tasks exist at any time, each walking one root.
/// Everything else (expanding roots, merging, ordering, de-duplicating) happens in the single parent task,
/// so no state is shared between threads except the progress counters.
enum ScanRun {
    /// How much parallelism a request gets after clamping.
    struct Limits: Equatable {
        var roots: Int
        var workers: Int

        init(roots: Int, workers: Int) {
            self.roots = roots
            self.workers = workers
        }

        init(_ request: ScanRequest, cores: Int = ProcessInfo.processInfo.activeProcessorCount) {
            let budget = max(1, min(8, cores))
            roots = max(1, min(request.maxConcurrentRoots, budget))
            workers = max(1, min(request.workersPerRoot, budget / roots))
        }
    }

    /// Progress is passed on at most this often.
    static let progressInterval = Duration.milliseconds(100)

    /// Runs the scan. Events go to `emit` in order, except `.progress`, which may come from walker threads.
    /// Does not emit `.finished`; the caller does that with the returned report.
    ///
    /// When the calling task is cancelled the walks stop within about 100 ms and the report is partial.
    @concurrent
    static func execute(_ request: ScanRequest, emit: @escaping @Sendable (ScanEvent) -> Void) async -> ScanReport {
        let clock = ContinuousClock()
        let started = clock.now
        let limits = Limits(request)
        let context = ScanContext(
            policy: PathPolicy(environment: request.environment, userExclusions: request.userExclusions),
            environment: request.environment,
            workers: limits.workers,
            progress: ProgressAggregator(interval: progressInterval) { files, bytes in
                emit(.progress(files: files, allocatedBytes: bytes))
            }
        )

        var plan = RunPlan(request: request, clock: clock, emit: emit)
        await withTaskGroup(of: (Int, RootOutcome).self) { group in
            var inFlight = 0
            while true {
                while inFlight < limits.roots, !Task.isCancelled, let unit = plan.nextUnit() {
                    group.addTask {
                        (unit.ruleIndex, await RootScanner.scan(
                            rule: unit.rule, root: unit.root, slot: unit.slot, context: context))
                    }
                    inFlight += 1
                }
                plan.flush()
                guard inFlight > 0, let (ruleIndex, outcome) = await group.next() else { break }
                inFlight -= 1
                plan.absorb(outcome, forRule: ruleIndex)
            }
        }
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

/// One root to walk for one rule.
private struct Unit: Sendable {
    let ruleIndex: Int
    let rule: Rule
    let root: URL
    let slot: Int
}

/// Everything the parent task tracks: which rules are expanded, which roots are queued, and what each
/// rule has collected. Results leave in request order so that "first rule wins" is deterministic.
private struct RunPlan {
    private struct RuleState {
        var expanded = false
        var remaining = 0
        var forcedPartial = false
        var started: ContinuousClock.Instant?
        var finished: ContinuousClock.Instant?
        var findings: [Finding] = []
        var skipped: [SkipReason: Int] = [:]
        var measuredBytes: Int64 = 0
        var measuredPrivateBytes: Int64 = 0
        var needsAccess: [URL] = []
        var missing: [URL] = []
        var excluded: [URL] = []
        var partial = false

        var isReady: Bool { finished != nil }
    }

    private static let listCap = 50

    private let request: ScanRequest
    private let clock: ContinuousClock
    private let emit: @Sendable (ScanEvent) -> Void
    /// Resolved roots of every rule, known before any rule is matched.
    private let ruleRoots: [RuleRoots]
    /// Which items hold another rule's root.
    private let overlap: RootOverlap
    private var states: [RuleState]
    private var queue: [Unit] = []
    private var queueHead = 0
    private var nextRule = 0
    private var nextSlot = 0
    private var emitted = 0
    private var claimed = Set<String>()
    private(set) var results: [RuleResult] = []
    private(set) var duplicatesDropped = 0

    init(request: ScanRequest, clock: ContinuousClock, emit: @escaping @Sendable (ScanEvent) -> Void) {
        self.request = request
        self.clock = clock
        self.emit = emit
        self.states = Array(repeating: RuleState(), count: request.rules.count)
        let roots = request.rules.map { RuleRoots.resolve($0, in: request.environment) }
        self.ruleRoots = roots
        self.overlap = RootOverlap(rules: request.rules, roots: roots)
    }

    /// The next root to walk, expanding the next rule's roots when the queue is empty.
    /// Returns nil when nothing is left to start.
    mutating func nextUnit() -> Unit? {
        while true {
            if queueHead < queue.count {
                defer { queueHead += 1 }
                return queue[queueHead]
            }
            queue.removeAll(keepingCapacity: true)
            queueHead = 0
            guard nextRule < request.rules.count else { return nil }
            expand(ruleAt: nextRule)
            nextRule += 1
        }
    }

    /// Merges a finished root into its rule.
    mutating func absorb(_ outcome: RootOutcome, forRule index: Int) {
        var state = states[index]
        for finding in outcome.findings {
            // An item that holds another rule's root is that rule's to offer, not ours.
            if overlap.isCovered(finding.url, byRuleOtherThan: index) {
                state.skipped[.coveredByOtherRule, default: 0] += 1
            } else {
                state.findings.append(finding)
            }
        }
        for (reason, count) in outcome.skipped { state.skipped[reason, default: 0] += count }
        state.measuredBytes += outcome.measuredBytes
        state.measuredPrivateBytes += outcome.measuredPrivateBytes
        Self.append(outcome.needsAccess, to: &state.needsAccess)
        Self.append(outcome.missing, to: &state.missing)
        state.partial = state.partial || outcome.partial
        state.remaining -= 1
        if state.remaining == 0 { state.finished = clock.now }
        states[index] = state
    }

    /// Marks every rule that has not finished as partial and finished. Used after cancellation.
    mutating func abandonUnfinished() {
        for index in states.indices where !states[index].isReady {
            states[index].forcedPartial = true
            states[index].finished = clock.now
            if states[index].started == nil { states[index].started = states[index].finished }
        }
    }

    /// Emits `.ruleFinished` for every rule at the front of the order that is done.
    mutating func flush() {
        while emitted < states.count, states[emitted].isReady {
            let result = makeResult(at: emitted)
            results.append(result)
            emit(.ruleFinished(result))
            emitted += 1
        }
    }

    // MARK: - Private

    private mutating func expand(ruleAt index: Int) {
        let rule = request.rules[index]
        var state = states[index]
        state.expanded = true
        state.started = clock.now
        emit(.ruleStarted(rule.id))

        // Roots were resolved up front (`ruleRoots`). Rules that are not walked (owner commands,
        // computed rows) have none, so they finish at once.
        let resolution = ruleRoots[index]
        state.partial = resolution.incomplete
        state.needsAccess = resolution.needsAccess
        state.missing = resolution.missing
        state.excluded = resolution.excluded
        for root in resolution.roots {
            queue.append(Unit(ruleIndex: index, rule: rule, root: root, slot: nextSlot))
            nextSlot += 1
            state.remaining += 1
        }
        if state.remaining == 0 { state.finished = clock.now }
        states[index] = state
    }

    private mutating func makeResult(at index: Int) -> RuleResult {
        let rule = request.rules[index]
        var state = states[index]
        var findings = state.findings.sorted { $0.url.plainPath < $1.url.plainPath }
        // First rule in request order keeps a path; later rules lose it.
        findings = findings.filter { finding in
            let inserted = claimed.insert(finding.url.plainPath).inserted
            if !inserted { duplicatesDropped += 1 }
            return inserted
        }
        state.findings = []
        var measured = state.measuredBytes
        var measuredPrivate = state.measuredPrivateBytes
        if rule.tier != .info, !isMeasureOnly(rule) {
            measured = findings.reduce(0) { $0 + $1.allocatedBytes }
            measuredPrivate = findings.reduce(0) { $0 + $1.privateBytes }
        }
        let start = state.started ?? clock.now
        return RuleResult(
            ruleID: rule.id,
            findings: findings,
            skippedCounts: state.skipped,
            measuredBytes: measured,
            measuredPrivateBytes: measuredPrivate,
            needsAccess: state.needsAccess.sorted { $0.plainPath < $1.plainPath },
            missingRoots: state.missing.sorted { $0.plainPath < $1.plainPath },
            excludedRoots: state.excluded.sorted { $0.plainPath < $1.plainPath },
            partial: state.partial || state.forcedPartial,
            duration: start.duration(to: state.finished ?? clock.now)
        )
    }

    private func isMeasureOnly(_ rule: Rule) -> Bool {
        if case .measureOnly = rule.match { return true }
        return false
    }

    private static func append(_ urls: [URL], to list: inout [URL]) {
        for url in urls where list.count < listCap && !list.contains(url) {
            list.append(url)
        }
    }
}
