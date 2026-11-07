import CleanerScanner
import Foundation
import Observation

/// App-wide state shared by every page.
@Observable @MainActor
final class AppModel {
    /// The page shown in the detail column.
    var selection: Page = .overview

    /// Data for the Overview page.
    let overview = OverviewModel()

    /// Data for the Large & Old Files page.
    let largeFiles = LargeFilesModel()
    /// Data for the Space Lens page.
    let spaceLens = SpaceLensModel()

    /// Data for the Trash page.
    let trash: TrashModel
    /// Data for the History page.
    let cleanHistory: HistoryModel

    /// Objects shared by pages that clean or read history, such as the one `HistoryStore`.
    let services: Services

    /// Delete mode, exclusions, disabled rules and the update switch.
    let settings: SettingsStore
    /// The once-a-day check for a newer build.
    let updates: UpdateChecker

    /// Full Disk Access as of the last probe. Pages that need access read this.
    private(set) var access: AccessState = .unknown

    @ObservationIgnored private var isProbingAccess = false

    init() {
        let settings = SettingsStore()
        self.settings = settings
        self.updates = UpdateChecker(settings: settings)
        let services = Services()
        self.services = services
        self.trash = TrashModel(services: services, settings: settings)
        self.cleanHistory = HistoryModel(services: services)
    }

    /// Probes Full Disk Access off the main actor and publishes the answer in ``access``.
    ///
    /// Call when the app becomes active, and from "Check Again". A probe that is already
    /// running is not started twice.
    func refreshAccess() async {
        guard !isProbingAccess else { return }
        isProbingAccess = true
        defer { isProbingAccess = false }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let state = await AccessProbe.fullDiskAccess(home: home)
        guard !Task.isCancelled else { return }
        access = state
    }
}
