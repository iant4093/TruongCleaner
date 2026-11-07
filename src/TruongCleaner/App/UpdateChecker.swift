import Foundation
import Observation
import os

/// A published build, read from the GitHub Releases API.
nonisolated struct ReleaseInfo: Equatable, Sendable {
    /// Build number inside the tag (`build-N` gives N).
    let tagNumber: Int
    /// Release title.
    let name: String
    /// Page of the release on github.com.
    let pageURL: URL

    /// Offset between a tag number and `CFBundleVersion` (CI adds it to the run number).
    static let bundleVersionOffset = 1000

    /// The number the running app would report as `CFBundleVersion` for this release.
    var buildNumber: Int { tagNumber + Self.bundleVersionOffset }
}

/// Reads the GitHub "latest release" JSON. Pure, so it needs no network to check.
nonisolated enum ReleaseParser {
    private nonisolated struct Payload: Decodable {
        let tag_name: String
        let name: String?
        let html_url: String
    }

    /// Returns the release, or `nil` when the JSON is malformed, the tag is not `build-N`, or the
    /// page is not an https github.com URL (the app only ever opens that).
    static func parse(_ data: Data) -> ReleaseInfo? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.tag_name.hasPrefix("build-"),
              let number = Int(payload.tag_name.dropFirst("build-".count)),
              number >= 0,
              let url = URL(string: payload.html_url),
              url.scheme == "https",
              url.host() == "github.com"
        else { return nil }
        let name = payload.name.flatMap { $0.isEmpty ? nil : $0 } ?? payload.tag_name
        return ReleaseInfo(tagNumber: number, name: name, pageURL: url)
    }

    /// True when the release is newer than the running `CFBundleVersion`. An unreadable running
    /// version counts as "not newer": unknown means no banner.
    static func isNewer(_ release: ReleaseInfo, than runningBundleVersion: String?) -> Bool {
        guard let runningBundleVersion, let running = Int(runningBundleVersion) else { return false }
        return release.buildNumber > running
    }
}

/// Asks GitHub once a day whether a newer build exists. The only network request in the app
/// (REQ-DIST-05).
@Observable @MainActor
final class UpdateChecker {
    /// Result of the last manual check, for the Settings page.
    enum ManualResult: Equatable {
        case upToDate
        case available(Int)
        case failed
    }

    static let endpoint = URL(string: "https://api.github.com/repos/iant4093/TruongCleaner/releases/latest")
    static let installCommand =
        "curl -fsSL https://github.com/iant4093/TruongCleaner/releases/latest/download/install.sh | sh"
    static let minimumInterval: TimeInterval = 24 * 60 * 60
    static let lastCheckedKey = "updateLastChecked"
    static let dismissedBuildKey = "updateDismissedBuild"

    private nonisolated static let log = Logger(subsystem: "com.iant4093.TruongCleaner", category: "updates")

    /// A newer release the user has not dismissed, or `nil`.
    var available: ReleaseInfo? {
        guard let latest, latest.buildNumber > dismissedBuild else { return nil }
        return latest
    }

    /// When the last check finished, successful or not.
    private(set) var lastChecked: Date?
    /// True while a request is running.
    private(set) var isChecking = false
    /// Outcome of the last user-started check; `nil` before one runs.
    private(set) var manualResult: ManualResult?

    private var latest: ReleaseInfo?
    private var dismissedBuild: Int

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let runningVersion: String?

    init(
        settings: SettingsStore,
        defaults: UserDefaults = .standard,
        runningVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    ) {
        self.settings = settings
        self.defaults = defaults
        self.runningVersion = runningVersion
        self.lastChecked = defaults.object(forKey: Self.lastCheckedKey) as? Date
        self.dismissedBuild = defaults.integer(forKey: Self.dismissedBuildKey)
    }

    /// Checks now when the toggle is on and the last check is older than 24 hours.
    func checkIfDue() async {
        guard settings.checksForUpdatesAutomatically else { return }
        if let lastChecked, Date.now.timeIntervalSince(lastChecked) < Self.minimumInterval,
           lastChecked <= Date.now { return }
        await check(manual: false)
    }

    /// Checks now, because the user pressed "Check Now".
    func checkNow() async {
        await check(manual: true)
    }

    /// Hides the banner until a newer build is published.
    func dismiss() {
        guard let latest else { return }
        dismissedBuild = latest.buildNumber
        defaults.set(dismissedBuild, forKey: Self.dismissedBuildKey)
    }

    // MARK: Private

    private func check(manual: Bool) async {
        guard !isChecking, let endpoint = Self.endpoint else { return }
        isChecking = true
        defer { isChecking = false }
        if manual { manualResult = nil }

        let release = await Self.fetchLatest(endpoint)
        // A cancelled request says nothing about GitHub, so it does not count as an attempt.
        guard !Task.isCancelled else { return }
        // The attempt counts toward the daily limit even when it failed.
        let now = Date.now
        lastChecked = now
        defaults.set(now, forKey: Self.lastCheckedKey)

        guard let release else {
            if manual { manualResult = .failed }
            return
        }
        if ReleaseParser.isNewer(release, than: runningVersion) {
            latest = release
            if manual { manualResult = .available(release.buildNumber) }
        } else {
            latest = nil
            if manual { manualResult = .upToDate }
        }
    }

    /// One GET with an ephemeral session: no cookies, no cache, 10 s timeout. Returns `nil` on any failure.
    @concurrent
    private static func fetchLatest(_ endpoint: URL) async -> ReleaseInfo? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TruongCleaner", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                log.info("Update check: unexpected response")
                return nil
            }
            guard let release = ReleaseParser.parse(data) else {
                log.info("Update check: could not read the release")
                return nil
            }
            return release
        } catch {
            log.info("Update check failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
