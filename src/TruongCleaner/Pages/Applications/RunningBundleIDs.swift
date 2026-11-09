import AppKit

/// Which apps are running right now, from `NSWorkspace` (an `NSRunningApplication` list).
@MainActor
enum RunningBundleIDs {
    /// Lower-cased bundle identifiers of every running app, or `nil` when the list cannot be trusted.
    ///
    /// The list always holds at least this app, so an empty one means the read failed. Unknown means
    /// keep: the caller then treats every app as "could not tell if it is running".
    static func current() -> Set<String>? {
        let apps = NSWorkspace.shared.runningApplications
        guard !apps.isEmpty else { return nil }
        return Set(apps.filter { !$0.isTerminated }.compactMap { $0.bundleIdentifier?.lowercased() })
    }
}
