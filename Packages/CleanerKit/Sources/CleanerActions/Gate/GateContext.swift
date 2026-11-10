import CleanerCore
import Foundation

/// Whether the app or process that owns a rule's data is running.
public enum OwnerState: Sendable, Hashable {
    /// The owner is running.
    case running
    /// The owner is not running.
    case notRunning
    /// The state could not be determined. The gate treats this like running.
    case unknown
}

/// Answers whether a rule's owner is running. The app layer wraps `NSRunningApplication`.
public protocol RunningAppsProvider: Sendable {
    /// The state of `owner` for the item about to be removed.
    ///
    /// The gate resolves `OwnerSpec.childNameAsBundleID` and `.rootSegmentAsBundleID` into
    /// `.bundleID` before asking, so providers normally see only `.bundleID` and `.processName`.
    /// A `.bundleID` that ends in `*` is a prefix (`com.adobe.PremierePro.*`). The gate answers it
    /// itself from the running processes and does not pass it to the provider.
    func state(of owner: OwnerSpec, for item: URL) async -> OwnerState
}

/// Answers whether any process has a file open inside an item.
public protocol OpenFilesProvider: Sendable {
    /// `true` when a process has the item, or a file inside it, open.
    /// `false` when none does. `nil` when this could not be determined.
    func hasOpenFiles(under url: URL) async -> Bool?
}

/// Everything `SafetyGate.authorize` needs besides the finding and its rule.
public struct GateContext: Sendable {
    /// Home folder and clock.
    public var environment: Environment
    /// Protected list and user exclusions.
    public var policy: PathPolicy
    /// The rule's concrete roots, as they were scanned.
    public var expandedRoots: [URL]
    /// Owner liveness.
    public var runningApps: any RunningAppsProvider
    /// Open-file liveness.
    public var openFiles: any OpenFilesProvider
    /// Owners that a root adds for items under it, keyed by the root as it was scanned.
    ///
    /// The gate also reads `RootSpec.owners` from the rule itself, so a context that leaves this
    /// empty is still safe. Entries here are added to those, never in place of them.
    public var rootOwners: [URL: [OwnerSpec]]
    /// True only for rule `installers.macOS`: the whole `.app` may be removed, never anything inside it.
    public var allowWholeBundle: Bool
    /// Reads who signed an app. Used only for `installers.macOS`. Tests replace it.
    public var appSignature: any AppSignatureChecker
    /// Asks git whether a path is tracked. Used only for `dev.projectArtifacts`. Tests replace it.
    public var git: any GitTrackingProbe

    /// Creates a context.
    public init(
        environment: Environment,
        policy: PathPolicy,
        expandedRoots: [URL],
        runningApps: any RunningAppsProvider,
        openFiles: any OpenFilesProvider,
        allowWholeBundle: Bool = false,
        rootOwners: [URL: [OwnerSpec]] = [:],
        appSignature: any AppSignatureChecker = SecurityAppSignatureChecker(),
        git: any GitTrackingProbe = GitCommandProbe()
    ) {
        self.environment = environment
        self.policy = policy
        self.expandedRoots = expandedRoots
        self.runningApps = runningApps
        self.openFiles = openFiles
        self.allowWholeBundle = allowWholeBundle
        self.rootOwners = rootOwners
        self.appSignature = appSignature
        self.git = git
    }
}
