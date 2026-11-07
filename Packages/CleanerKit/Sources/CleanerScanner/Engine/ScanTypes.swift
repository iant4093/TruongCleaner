import CleanerCore
import Foundation

/// What to scan: the rules, where "home" is, and how much parallelism to use.
public struct ScanRequest: Sendable {
    /// Rules in priority order. When two rules find the same path, the earlier rule keeps it.
    public var rules: [Rule]
    /// Home folder, Darwin directories and the clock.
    public var environment: Environment
    /// Folders the user excluded in Settings. Nothing inside or above them is offered.
    public var userExclusions: [URL]
    /// Roots walked at the same time. Clamped so that `maxConcurrentRoots * workersPerRoot` is at most
    /// `min(8, activeProcessorCount)`.
    public var maxConcurrentRoots: Int
    /// Walker threads per root.
    public var workersPerRoot: Int

    /// Creates a request.
    public init(
        rules: [Rule],
        environment: Environment,
        userExclusions: [URL] = [],
        maxConcurrentRoots: Int = 2,
        workersPerRoot: Int = 4
    ) {
        self.rules = rules
        self.environment = environment
        self.userExclusions = userExclusions
        self.maxConcurrentRoots = maxConcurrentRoots
        self.workersPerRoot = workersPerRoot
    }
}

/// What a scan found for one rule.
public struct RuleResult: Sendable {
    /// ID of the rule.
    public let ruleID: String
    /// Items the rule offers, sorted by path. Empty for Info rules.
    public let findings: [Finding]
    /// Candidates the matcher rejected, counted by reason.
    public let skippedCounts: [SkipReason: Int]
    /// Info rules: allocated bytes of the rule's roots. Other rules: allocated bytes of the findings.
    public let measuredBytes: Int64
    /// Info rules: private bytes of the rule's roots. Other rules: private bytes of the findings.
    public let measuredPrivateBytes: Int64
    /// Roots or folders macOS would not open (`EPERM`/`EACCES`), at most 50. Their size is unknown, not zero.
    public let needsAccess: [URL]
    /// Roots that do not exist, or are not real folders. Not an error. At most 50.
    public let missingRoots: [URL]
    /// Folders the rule leaves out on purpose (`Guards.excludeRootSegments`): the folder that a `*`
    /// of a root stood for, such as `Containers/com.apple.Notes`. They are not opened or walked and
    /// their size is not counted. At most 50.
    public let excludedRoots: [URL]
    /// True when the scan was stopped, or a root could not be fully read for a reason other than permission.
    /// Sizes are then incomplete. Items whose age mattered were not offered.
    public let partial: Bool
    /// Wall time from the rule's start until its last root finished.
    public let duration: Duration

    /// Creates a result.
    public init(
        ruleID: String,
        findings: [Finding],
        skippedCounts: [SkipReason: Int],
        measuredBytes: Int64,
        measuredPrivateBytes: Int64,
        needsAccess: [URL],
        missingRoots: [URL],
        excludedRoots: [URL] = [],
        partial: Bool,
        duration: Duration
    ) {
        self.ruleID = ruleID
        self.findings = findings
        self.skippedCounts = skippedCounts
        self.measuredBytes = measuredBytes
        self.measuredPrivateBytes = measuredPrivateBytes
        self.needsAccess = needsAccess
        self.missingRoots = missingRoots
        self.excludedRoots = excludedRoots
        self.partial = partial
        self.duration = duration
    }
}

/// One step in a running scan.
public enum ScanEvent: Sendable {
    /// The engine began working on a rule.
    case ruleStarted(String)
    /// Files and allocated bytes counted so far across all walks. At most 10 per second.
    case progress(files: Int, allocatedBytes: Int64)
    /// A rule is done. Results arrive in request order.
    case ruleFinished(RuleResult)
    /// The scan is over. Always the last event.
    case finished(ScanReport)
}

/// Everything a scan found.
public struct ScanReport: Sendable {
    /// One result per rule, in request order.
    public let results: [RuleResult]
    /// True when any rule is partial or the scan was cancelled.
    public let partial: Bool
    /// Wall time of the whole scan.
    public let duration: Duration
    /// Findings dropped because an earlier rule already offered the same path.
    public let duplicatesDropped: Int

    /// Creates a report.
    public init(results: [RuleResult], partial: Bool, duration: Duration, duplicatesDropped: Int) {
        self.results = results
        self.partial = partial
        self.duration = duration
        self.duplicatesDropped = duplicatesDropped
    }
}
