import CleanerCore
import Foundation

/// One root to walk for one rule.
struct Unit: Sendable {
    let ruleIndex: Int
    let rule: Rule
    let root: URL
    let slot: Int
}

/// Everything the parent task tracks: which roots are queued and what each rule has collected.
///
/// Roots are known for every rule before the first walk starts. Rules are delivered as they finish;
/// a result waits only for earlier rules that could offer one of its paths (`ClaimGuard`), so that
/// "first rule wins" stays exact. `results` is always in request order.
struct RunPlan {
    private struct RuleState {
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
    private let deliverEarly: Bool
    /// Which items hold another rule's root.
    private let overlap: RootOverlap
    private let claimGuard: ClaimGuard
    private var states: [RuleState]
    private var startedAnnounced: [Bool]
    private var queue: [Unit] = []
    private var queueHead = 0
    private var delivered: [RuleResult?]
    private var deliveredCount = 0
    private var claimed = Set<String>()
    private(set) var duplicatesDropped = 0

    /// - Parameters:
    ///   - request: The scan.
    ///   - clock: Time source for rule durations.
    ///   - largestFirst: Start the roots with the most entries first.
    ///   - deliverEarly: Deliver a finished rule before earlier rules when that cannot change the result.
    ///   - emit: Receives `.ruleStarted` and `.ruleFinished`.
    init(
        request: ScanRequest, clock: ContinuousClock, largestFirst: Bool, deliverEarly: Bool,
        emit: @escaping @Sendable (ScanEvent) -> Void
    ) {
        self.request = request
        self.clock = clock
        self.emit = emit
        self.deliverEarly = deliverEarly
        let count = request.rules.count
        self.states = Array(repeating: RuleState(), count: count)
        self.startedAnnounced = Array(repeating: false, count: count)
        self.delivered = Array(repeating: nil, count: count)
        // Planning reads the file system (`*` levels list folders, hints read names), so it checks for
        // cancellation between rules and between roots. After a stop the remaining rules get no roots
        // and are marked partial, and the scan goes straight to its report (REQ-SCAN-05).
        let roots = request.rules.map { rule -> RuleRoots in
            guard !Task.isCancelled else { return RuleRoots(incomplete: true) }
            return RuleRoots.resolve(rule, in: request.environment)
        }
        // Whether an item holds the root of another rule does not depend on that rule being enabled:
        // turning a rule off must not make its folder easier to offer from a broader rule. So the overlap
        // covers the whole catalog, plus any requested rule that is not in it.
        self.overlap = Self.makeOverlap(request: request, requestRoots: roots)
        self.claimGuard = ClaimGuard(rules: request.rules, roots: roots)

        var hinted: [(unit: Unit, hint: Int)] = []
        var slot = 0
        for (index, rule) in request.rules.enumerated() {
            // Rules that are not walked (owner commands, computed rows) have no roots and finish at once.
            let resolution = roots[index]
            states[index].partial = resolution.incomplete
            states[index].needsAccess = resolution.needsAccess
            states[index].missing = resolution.missing
            states[index].excluded = resolution.excluded
            states[index].remaining = resolution.roots.count
            for root in resolution.roots {
                let hint = largestFirst && !Task.isCancelled ? RootHint.entryCount(of: root) : 0
                hinted.append((Unit(ruleIndex: index, rule: rule, root: root, slot: slot), hint))
                slot += 1
            }
        }
        if largestFirst {
            // Biggest first; equal hints keep request order.
            hinted.sort { $0.hint != $1.hint ? $0.hint > $1.hint : $0.unit.slot < $1.unit.slot }
        }
        queue = hinted.map(\.unit)
        for index in states.indices where states[index].remaining == 0 {
            announceStart(of: index)
            states[index].finished = clock.now
        }
    }

    /// Builds the overlap guard from every catalog rule that can offer items, and from the request's rules.
    /// Roots of the requested rules are reused; the others are resolved here.
    private static func makeOverlap(request: ScanRequest, requestRoots: [RuleRoots]) -> RootOverlap {
        var rules = request.rules
        var roots = requestRoots
        var known = Set(rules.map(\.id))
        for rule in Catalog.all where RuleRoots.offersItems(rule) && known.insert(rule.id).inserted {
            if Task.isCancelled { break }
            rules.append(rule)
            roots.append(RuleRoots.resolve(rule, in: request.environment))
        }
        return RootOverlap(rules: rules, roots: roots)
    }

    /// True while roots are waiting to start.
    var hasQueuedUnits: Bool { queueHead < queue.count }

    /// The next root to walk. Announces the rule's start when its first root begins.
    mutating func nextUnit() -> Unit? {
        guard queueHead < queue.count else { return nil }
        let unit = queue[queueHead]
        queueHead += 1
        announceStart(of: unit.ruleIndex)
        return unit
    }

    /// Merges a finished root into its rule.
    mutating func absorb(_ outcome: RootOutcome, forRule index: Int) {
        var state = states[index]
        for finding in outcome.findings {
            // An item that holds another rule's root is that rule's to offer, not ours.
            if overlap.isCovered(finding.url, byRuleOtherThan: request.rules[index].id) {
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
            announceStart(of: index)
            states[index].forcedPartial = true
            states[index].finished = clock.now
        }
    }

    /// Delivers every finished rule that may go now.
    mutating func flush() {
        guard deliveredCount < delivered.count else { return }
        var progressed = true
        while progressed {
            progressed = false
            for index in delivered.indices where delivered[index] == nil && states[index].isReady {
                if canDeliver(index) {
                    deliver(index)
                    progressed = true
                }
            }
        }
    }

    /// One result per rule, in request order. Rules not yet delivered are left out.
    var results: [RuleResult] { delivered.compactMap { $0 } }

    // MARK: - Private

    private mutating func announceStart(of index: Int) {
        guard !startedAnnounced[index] else { return }
        startedAnnounced[index] = true
        states[index].started = clock.now
        emit(.ruleStarted(request.rules[index].id))
    }

    /// A rule goes when every earlier rule is delivered, or none of the earlier ones can offer its paths.
    private func canDeliver(_ index: Int) -> Bool {
        let earlierPending = delivered[..<index].contains { $0 == nil }
        if !earlierPending { return true }
        guard deliverEarly else { return false }
        return claimGuard.mayDeliver(
            rule: index, paths: states[index].findings.map(\.url), pending: { delivered[$0] == nil })
    }

    private mutating func deliver(_ index: Int) {
        let result = makeResult(at: index)
        delivered[index] = result
        deliveredCount += 1
        emit(.ruleFinished(result))
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
