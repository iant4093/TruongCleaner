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
    /// Data for the Smart Clean page.
    let smartClean: SmartCleanModel

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
        self.smartClean = SmartCleanModel(settings: settings)
    }

    /// What the toolbar's Scan button (⌘R) does on the current page.
    struct ToolbarScan {
        /// True while the page's scan runs; the button then stops it.
        let isRunning: Bool
        /// False when the page cannot scan or stop right now.
        let isEnabled: Bool
        /// Starts or stops the scan.
        let perform: () -> Void
    }

    /// The toolbar Scan button for the selected page, or `nil` when the page has no scan to start.
    var toolbarScan: ToolbarScan? {
        switch selection {
        case .smartClean:
            let model = smartClean
            return ToolbarScan(
                isRunning: model.isScanning,
                isEnabled: model.isScanning || model.canScan,
                perform: { model.isScanning ? model.stopScan() : model.scan() }
            )
        default:
            return nil
        }
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
