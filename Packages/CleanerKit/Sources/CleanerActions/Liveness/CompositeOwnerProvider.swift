import CleanerCore
import Foundation

/// Asks two providers in order and returns the first answer that is not `.unknown`.
///
/// The app layer uses it to combine its bundle-ID provider with `ProcessNameOwnerProvider`.
/// If both say `.unknown`, so does this provider, and the gate keeps the item.
public struct CompositeOwnerProvider: RunningAppsProvider {
    private let first: any RunningAppsProvider
    private let second: any RunningAppsProvider

    /// Creates a provider that asks `first`, then `then`.
    public init(first: any RunningAppsProvider, then second: any RunningAppsProvider) {
        self.first = first
        self.second = second
    }

    /// The first non-`.unknown` answer, or `.unknown`.
    public func state(of owner: OwnerSpec, for item: URL) async -> OwnerState {
        let answer = await first.state(of: owner, for: item)
        if answer != .unknown { return answer }
        return await second.state(of: owner, for: item)
    }
}
