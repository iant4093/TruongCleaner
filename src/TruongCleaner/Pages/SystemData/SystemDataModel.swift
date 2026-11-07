import CleanerCore
import CleanerScanner
import Foundation
import Observation

/// Measures what macOS lumps into "System Data" and holds the rows the page shows.
///
/// Everything here only reads. The scan, the probes and the `tmutil` and `simctl` calls run off the main actor.
@Observable @MainActor
final class SystemDataModel {
    /// A load that finished less than this long ago is not repeated when the page reappears.
    static let minimumRefreshInterval: Duration = .seconds(300)

    /// The last finished load. Stays on screen while a new load runs.
    private(set) var report: SystemDataReport?
    /// True while a load runs.
    private(set) var isLoading = false
    /// Set when no scan could run. Cleared by the next load.
    private(set) var failure: String?

    /// True when Full Disk Access was granted after the numbers on screen were measured (REQ-PERM-03).
    /// The page offers a new scan; it never starts one by itself.
    private(set) var accessChangedSinceLoad = false

    @ObservationIgnored private var lastLoad: ContinuousClock.Instant?

    /// Loads unless a recent load already exists. Call when the page appears.
    func loadIfNeeded(settings: SettingsStore) async {
        if report != nil, let lastLoad, lastLoad.duration(to: .now) < Self.minimumRefreshInterval {
            return
        }
        await refresh(settings: settings)
    }

    /// Marks the numbers on screen as measured before Full Disk Access was granted.
    ///
    /// Does nothing when nothing has been measured yet, because the next load already sees the new access.
    func noteAccessGranted() {
        if report != nil || isLoading { accessChangedSinceLoad = true }
    }

    /// Measures everything again and replaces ``report``.
    ///
    /// A load that is cancelled (the user left the page) changes nothing, so the next appearance loads again.
    func refresh(settings: SettingsStore) async {
        guard !isLoading else { return }
        isLoading = true
        accessChangedSinceLoad = false
        defer { isLoading = false }

        // Unknown means keep: an exclusions file we cannot read means we do not scan.
        guard let exclusions = await settings.loadedExclusions() else {
            failure = "TruongCleaner could not read your exclusions, so it did not scan. "
                + "Open Settings > Exclusions to start a new list."
            return
        }
        failure = nil

        let infoRules = settings.enabledRules.filter { $0.tier == .info }
        let measured = infoRules.filter { if case .measureOnly = $0.match { true } else { false } }
        let request = ScanRequest(
            rules: measured,
            environment: CleanerCore.Environment(home: FileManager.default.homeDirectoryForCurrentUser),
            userExclusions: exclusions
        )

        async let results = Self.measure(request)
        async let volume = VolumeInfo.current()
        async let snapshots = Snapshots.list()
        async let runtimes = Simulators.runtimes()
        async let swap = Self.readSwap()
        let inputs = await SystemDataInputs(
            rules: infoRules,
            results: results,
            volume: volume,
            snapshots: snapshots,
            swap: swap,
            runtimes: runtimes
        )
        guard !Task.isCancelled else { return }

        report = SystemDataBuilder.build(inputs)
        lastLoad = .now
    }

    /// Runs the scan and keeps each rule's result by ID. Rules that did not finish have no entry.
    @concurrent
    private static func measure(_ request: ScanRequest) async -> [String: RuleResult] {
        guard !request.rules.isEmpty else { return [:] }
        var results: [String: RuleResult] = [:]
        for await event in await ScanEngine().scan(request) {
            if case .ruleFinished(let result) = event { results[result.ruleID] = result }
        }
        return results
    }

    @concurrent
    private static func readSwap() async -> SwapUsage? {
        SwapProbe.current()
    }
}
