import CleanerScanner
import Foundation
import Observation

/// Holds the one category measurement that the Overview and System Data pages share.
///
/// The walk runs off the main actor. It keeps going when the user switches pages, and the user can
/// stop it. A stopped measurement is thrown away, so the pages never show half a measurement as final.
@Observable @MainActor
final class CategoryModel {
    /// A measurement that finished less than this long ago is not repeated unless the user asks.
    static let minimumRefreshInterval: Duration = .seconds(600)

    /// The last finished measurement. Stays on screen while a new one runs.
    private(set) var totals: CategoryTotals?
    /// True while a measurement runs.
    private(set) var isMeasuring = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastFinished: ContinuousClock.Instant?

    /// Starts a measurement unless one is running or the last one is under ten minutes old.
    func startIfNeeded() {
        start(force: false)
    }

    /// Starts a measurement. `force` skips the ten-minute rule; use it when the user asked for a new scan.
    /// Does nothing while a measurement is already running.
    func start(force: Bool) {
        guard !isMeasuring else { return }
        if !force, totals != nil, let lastFinished, lastFinished.duration(to: .now) < Self.minimumRefreshInterval {
            return
        }
        isMeasuring = true
        let home = FileManager.default.homeDirectoryForCurrentUser
        task = Task { [weak self] in
            let result = await CategoryScanner.measure(home: home)
            self?.finish(result, cancelled: Task.isCancelled)
        }
    }

    /// Stops the running measurement and keeps the previous result, if any.
    func cancel() {
        task?.cancel()
    }

    private func finish(_ result: CategoryTotals, cancelled: Bool) {
        isMeasuring = false
        task = nil
        guard !cancelled else { return }
        totals = result
        lastFinished = .now
    }
}
