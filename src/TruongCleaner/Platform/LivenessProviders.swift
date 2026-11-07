import CleanerActions
import CleanerCore
import Foundation

/// The liveness checks `GateContext` needs: is the owner running, does a process have the item open.
nonisolated enum LivenessProviders {
    /// A pair of providers for one gate context.
    struct Providers: Sendable {
        /// Owner liveness: running GUI apps first, then command-line processes by name.
        let runningApps: any RunningAppsProvider
        /// Open-file liveness (`libproc`).
        let openFiles: any OpenFilesProvider
    }

    /// Builds the providers the app uses for every clean.
    ///
    /// - Parameters:
    ///   - roots: The rule's concrete roots, for owners that depend on where an item lies.
    ///   - rootSpecs: The rule's root specs.
    static func make(roots: [URL] = [], rootSpecs: [RootSpec] = []) -> Providers {
        Providers(
            runningApps: CompositeOwnerProvider(
                first: AppRunningAppsProvider(roots: roots, rootSpecs: rootSpecs),
                then: ProcessNameOwnerProvider(roots: roots, rootSpecs: rootSpecs)
            ),
            openFiles: ProcessOpenFilesProvider()
        )
    }
}
