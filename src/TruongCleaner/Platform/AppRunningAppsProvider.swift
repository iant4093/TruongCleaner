import AppKit
import CleanerActions
import CleanerCore
import Foundation

/// Tells `SafetyGate` whether a GUI app is running, from `NSWorkspace` (REQ-SAFE-07).
///
/// - `.bundleID` is answered from the running-application list, read on the main actor.
/// - `.childNameAsBundleID` and `.rootSegmentAsBundleID` are read like the kit does: the item's
///   folder name (or the root's path segment) is taken as a bundle identifier when it looks like
///   one. The gate normally resolves these before it asks, so they only reach this provider when
///   `roots` and `rootSpecs` were given.
/// - `.processName` is `.unknown`, so `CompositeOwnerProvider` falls through to
///   `ProcessNameOwnerProvider`.
///
/// Unknown means keep: an empty application list is reported as `.unknown`, never as "not running".
nonisolated struct AppRunningAppsProvider: RunningAppsProvider {
    private let roots: [URL]
    private let rootSpecs: [RootSpec]

    /// Creates a provider.
    ///
    /// - Parameters:
    ///   - roots: The rule's concrete roots, used to read `.childNameAsBundleID`.
    ///   - rootSpecs: The rule's root specs, used to read `.rootSegmentAsBundleID`.
    init(roots: [URL] = [], rootSpecs: [RootSpec] = []) {
        self.roots = roots
        self.rootSpecs = rootSpecs
    }

    func state(of owner: OwnerSpec, for item: URL) async -> OwnerState {
        switch owner {
        case .bundleID(let identifier):
            return await Self.state(ofBundleID: identifier)
        case .processName:
            return .unknown
        case .childNameAsBundleID, .rootSegmentAsBundleID:
            let root = OwnerResolution.deepestRoot(containing: item, in: roots)
            switch OwnerResolution.target(for: owner, item: item, root: root, rootSpecs: rootSpecs) {
            case .noOwner:
                return .notRunning
            case .unresolvable:
                return .unknown
            case .ask(.bundleID(let identifier)):
                return await Self.state(ofBundleID: identifier)
            case .ask:
                return .unknown
            }
        }
    }

    /// Whether an app with this bundle identifier is running. Bundle identifiers are compared
    /// without regard to case.
    private static func state(ofBundleID identifier: String) async -> OwnerState {
        guard !identifier.isEmpty else { return .unknown }
        let wanted = identifier.lowercased()
        return await MainActor.run {
            let apps = NSWorkspace.shared.runningApplications
            // The list always holds at least this app. An empty list means the read failed.
            guard !apps.isEmpty else { return OwnerState.unknown }
            let running = apps.contains { app in
                !app.isTerminated && app.bundleIdentifier?.lowercased() == wanted
            }
            return running ? OwnerState.running : OwnerState.notRunning
        }
    }
}
