import CleanerCore
import Darwin
import Foundation

/// Answers owner questions for command-line processes by name.
///
/// `.processName(x)` is `.running` when a process is the tool `x`: named `x`, or running a script
/// named `x` (`node /usr/local/bin/npm`), or carrying a known marker in its arguments (the Gradle
/// daemon). See ``ProcessOwnerMatcher``. `.bundleID` is `.unknown`, because bundle identifiers need
/// `NSRunningApplication`, which the app layer supplies and combines with this provider through
/// `CompositeOwnerProvider`. The one exception is an identifier ending in `*` (a prefix such as
/// `com.adobe.PremierePro.*`), which is answered here from the running processes' app bundles.
///
/// `.childNameAsBundleID` and `.rootSegmentAsBundleID` are normally resolved by the gate before it
/// asks. If one arrives anyway, this provider finds the item's root among its `roots` and reads
/// the name the spec points at: a name that does not look like a bundle identifier has no owner
/// (`.notRunning`); anything else is `.unknown`, because a bundle identifier cannot be matched
/// against process names. `.rootSegmentAsBundleID` also needs the rule's `rootSpecs`; without
/// them the answer is `.unknown`.
public struct ProcessNameOwnerProvider: RunningAppsProvider {
    private let roots: [URL]
    private let rootSpecs: [RootSpec]

    /// Creates a provider.
    ///
    /// - Parameters:
    ///   - roots: The rule roots, used only to read `.childNameAsBundleID` and `.rootSegmentAsBundleID`.
    ///   - rootSpecs: The rule's root specs, used only to read `.rootSegmentAsBundleID`.
    public init(roots: [URL] = [], rootSpecs: [RootSpec] = []) {
        self.roots = roots
        self.rootSpecs = rootSpecs
    }

    /// The state of `owner`. See the type documentation for what each spec means here.
    @concurrent
    public func state(of owner: OwnerSpec, for item: URL) async -> OwnerState {
        switch owner {
        case .processName(let name):
            return Self.isProcessRunning(named: name)
        case .bundleID(let identifier):
            // Only a trailing `*` can be answered here, from the executable paths of running processes.
            // An exact bundle ID is the app layer's to answer.
            guard identifier.hasSuffix("*") else { return .unknown }
            return ProcessOwnerMatcher.state(ofBundleIDPrefix: String(identifier.dropLast()))
        case .childNameAsBundleID, .rootSegmentAsBundleID:
            let root = OwnerResolution.deepestRoot(containing: item, in: roots)
            switch OwnerResolution.target(for: owner, item: item, root: root, rootSpecs: rootSpecs) {
            case .noOwner: return .notRunning
            case .ask, .unresolvable: return .unknown
            }
        }
    }

    /// Whether a process of the tool called `name` is running, judged by name and by argument vector
    /// (see ``ProcessOwnerMatcher``). `.unknown` when the process list cannot be read or one of the
    /// user's interpreter processes cannot be inspected.
    static func isProcessRunning(named name: String) -> OwnerState {
        ProcessOwnerMatcher.state(ofProcessNamed: name)
    }
}
