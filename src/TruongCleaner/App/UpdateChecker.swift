import AppKit
import CleanerActions
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
    /// The two files an in-app update downloads, or `nil` when the release lacks them or their
    /// addresses are not on the allow-list (`UpdateURLPolicy`).
    let assets: UpdateAssets?

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
        let assets: [Asset]?
    }

    private nonisolated struct Asset: Decodable {
        let name: String
        let browser_download_url: String
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
        return ReleaseInfo(tagNumber: number, name: name, pageURL: url, assets: updateAssets(in: payload.assets ?? []))
    }

    /// `TruongCleaner.zip` and `SHA256SUMS`, if each appears exactly once with an allowed address.
    private static func updateAssets(in assets: [Asset]) -> UpdateAssets? {
        func address(of name: String) -> URL? {
            let matches = assets.filter { $0.name == name }
            guard matches.count == 1 else { return nil }
            return URL(string: matches[0].browser_download_url)
        }
        guard let archive = address(of: UpdateDownloader.archiveName), let sums = address(of: "SHA256SUMS") else {
            return nil
        }
        return UpdateAssets(archive: archive, checksums: sums)
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
    /// Where an in-app update is.
    enum InstallState: Equatable {
        case idle
        /// Downloading; the value is the fraction received.
        case downloading(Double)
        /// Unpacking and checking the download.
        case verifying
        /// Verified; about to be swapped in.
        case ready
        /// Swapping the app and relaunching.
        case installing
        /// Stopped; nothing was installed. Holds the message for the user.
        case failed(String)
    }

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

    /// The newest release found, newer than the running app, even if the banner was dismissed.
    private(set) var latest: ReleaseInfo?

    /// When the last check finished, successful or not.
    private(set) var lastChecked: Date?
    /// True while a request is running.
    private(set) var isChecking = false
    /// Outcome of the last user-started check; `nil` before one runs.
    private(set) var manualResult: ManualResult?

    /// Progress of the in-app update.
    private(set) var installState: InstallState = .idle

    /// Why the running app cannot replace itself where it is, read off the main actor when a release is found.
    private var locationBlocker: UpdateError?
    private var dismissedBuild: Int
    private var installTask: Task<Void, Never>?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let runningVersion: String?
    @ObservationIgnored private let installService = UpdateInstallService()

    /// Whether a clean, put-back, uninstall, empty-trash or owner command is running. An update
    /// restarts the app, which would cut that work off, so Install Update waits. `AppModel` sets it.
    @ObservationIgnored var isBusy: @MainActor () -> Bool = { false }

    /// Shown when Install Update is blocked, and when an update stops because work started meanwhile.
    static let busyMessage = "Wait for the clean to finish, then install the update."

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

    // MARK: In-app update

    /// "Version 1.0 (build 1001)" for the running app.
    static var versionText: String {
        let info = Bundle.main
        let version = info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = info.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Version \(version) (build \(build))"
    }

    /// Why the update cannot be installed from inside the app, or `nil` when it can.
    /// Plain words for the Settings page and the banner.
    var installBlocker: String? {
        guard let release = latest else { return "There is no newer build." }
        guard release.assets != nil else { return "This release has no update file the app can install." }
        if isBusy() { return Self.busyMessage }
        guard UpdateIdentity.current() != nil else { return "This copy of TruongCleaner cannot read its own version." }
        switch locationBlocker {
        case nil: return nil
        case .notWritable?: return "The folder that holds TruongCleaner is not writable. Use Terminal instead."
        case _?: return "Move TruongCleaner to the Applications folder to update it here, or use Terminal."
        }
    }

    /// True when Install Update can be pressed.
    var canInstall: Bool {
        guard installBlocker == nil else { return false }
        switch installState {
        case .idle, .failed: return true
        case .downloading, .verifying, .ready, .installing: return false
        }
    }

    /// True while a download or install is running.
    var isInstalling: Bool {
        switch installState {
        case .downloading, .verifying, .ready, .installing: true
        case .idle, .failed: false
        }
    }

    /// True while the download can still be cancelled.
    var canCancelInstall: Bool {
        switch installState {
        case .downloading, .verifying: true
        case .idle, .ready, .installing, .failed: false
        }
    }

    /// Downloads, checks and installs the newest build, then reopens the app.
    /// Nothing is installed unless every check passes; a failure leaves this version in place.
    func install() {
        guard canInstall, installTask == nil, let assets = latest?.assets,
              let identity = UpdateIdentity.current()
        else { return }
        installState = .downloading(0)
        installTask = Task { [weak self] in
            await self?.runInstall(assets: assets, identity: identity)
            self?.installTask = nil
        }
    }

    /// Stops a download in progress. No effect once the swap has begun.
    func cancelInstall() {
        guard canCancelInstall else { return }
        installTask?.cancel()
    }

    /// Removes what an earlier update left behind: the old app (to the Trash) and stale temporary
    /// folders. Runs once at launch, off the main actor.
    @concurrent
    static func removeLeftovers() async {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let appFolder = Bundle.main.bundleURL.deletingLastPathComponent()
        let report = await UpdateCleanup().removeLeftovers(in: appFolder, bundleIdentifier: identifier)
        if !report.trashedBundles.isEmpty || !report.removedFolders.isEmpty {
            log.info(
                "Update cleanup: \(report.trashedBundles.count) old app(s) trashed, \(report.removedFolders.count) folder(s) removed")
        }
    }

    // MARK: Private

    /// `stat` and `access` on the app's folder, off the main actor.
    @concurrent
    private static func readLocationBlocker() async -> UpdateError? {
        UpdateInstallService().blocker(for: Bundle.main.bundleURL)
    }

    private func runInstall(assets: UpdateAssets, identity: UpdateIdentity) async {
        let running = Bundle.main.bundleURL
        let service = installService
        do {
            let prepared = try await service.prepare(assets, identity: identity) { [weak self] stage in
                Task { @MainActor in self?.apply(stage) }
            }
            if Task.isCancelled {
                await service.discard(prepared)
                throw UpdateError.cancelled
            }
            // Work may have started during the download. Check again right before the swap.
            if isBusy() {
                await service.discard(prepared)
                installState = .failed(Self.busyMessage)
                return
            }
            installState = .ready
            installState = .installing
            _ = try await service.install(prepared, replacing: running)
        } catch UpdateError.cancelled, is CancellationError {
            installState = .idle
            return
        } catch {
            Self.log.info("Update failed: \(error.localizedDescription, privacy: .public)")
            installState = .failed((error as? UpdateError)?.errorDescription ?? error.localizedDescription)
            return
        }
        await relaunch(at: running)
    }

    private func apply(_ stage: UpdateStage) {
        switch (installState, stage) {
        case (.downloading, .downloading(let fraction)): installState = .downloading(fraction)
        case (.downloading, .verifying): installState = .verifying
        default: break
        }
    }

    /// Opens the new copy as a second instance, then quits this one.
    private func relaunch(at url: URL) async {
        // The swap is done. If work started since, do not cut it off: the user restarts later.
        if isBusy() {
            installState = .failed(
                "TruongCleaner was updated. Quit it and open it again when the current clean has finished.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            NSApp.terminate(nil)
        } catch {
            Self.log.info("Relaunch failed: \(error.localizedDescription, privacy: .public)")
            installState = .failed("TruongCleaner was updated, but could not reopen itself. Quit it and open it again.")
        }
    }

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
            locationBlocker = await Self.readLocationBlocker()
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
