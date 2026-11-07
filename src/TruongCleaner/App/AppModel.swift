import CleanerScanner
import Foundation
import Observation

/// App-wide state shared by every page.
@Observable @MainActor
final class AppModel {
    /// The page shown in the detail column.
    var selection: Page = .overview

    /// The category measurement that the Overview and System Data pages share.
    let categories: CategoryModel

    /// Data for the Overview page.
    let overview: OverviewModel

    /// Data for the System Data page.
    let systemData: SystemDataModel

    /// Data for the Large & Old Files page.
    let largeFiles = LargeFilesModel()
    /// Data for the Space Lens page.
    let spaceLens = SpaceLensModel()
    /// Data for the Smart Clean page.
    let smartClean: SmartCleanModel
    /// Data for the Developer page.
    let developer: DeveloperModel

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

    /// Whether onboarding is on screen. The first launch and Help > Welcome to TruongCleaner set it.
    var isOnboardingPresented = false

    @ObservationIgnored private var isProbingAccess = false
    @ObservationIgnored private var hasProbedAccess = false

    init() {
        let categories = CategoryModel()
        self.categories = categories
        self.overview = OverviewModel(categories: categories)
        self.systemData = SystemDataModel(categories: categories)
        let settings = SettingsStore()
        self.settings = settings
        self.updates = UpdateChecker(settings: settings)
        let services = Services()
        self.services = services
        self.smartClean = SmartCleanModel(settings: settings, services: services)
        self.developer = DeveloperModel(settings: settings, services: services)
        self.trash = TrashModel(services: services, settings: settings)
        self.cleanHistory = HistoryModel(services: services)
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
        case .developer:
            let model = developer
            return ToolbarScan(
                isRunning: model.files.isScanning,
                isEnabled: model.files.isScanning || model.canScan,
                perform: { model.files.isScanning ? model.files.stopScan() : model.scan() }
            )
        case .systemData:
            let model = systemData
            let settings = settings
            // A System Data load cannot be stopped, so the button is disabled while it runs.
            return ToolbarScan(
                isRunning: false,
                isEnabled: !model.isLoading,
                perform: { Task { await model.refresh(settings: settings) } }
            )
        case .largeFiles:
            let model = largeFiles
            return ToolbarScan(
                isRunning: model.isSearching,
                isEnabled: model.isSearching || !model.folders.isEmpty,
                perform: { model.isSearching ? model.stop() : model.find() }
            )
        case .spaceLens:
            let model = spaceLens
            return ToolbarScan(
                isRunning: model.isScanning,
                isEnabled: true,
                perform: {
                    if model.isScanning {
                        model.cancel()
                    } else if case .ready = model.state {
                        model.rescan()
                    } else {
                        model.scan()
                    }
                }
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
        let previous = access
        access = state
        // Only a real change counts: the first probe replaces the "not probed yet" default.
        if hasProbedAccess, state == .granted, previous != .granted {
            smartClean.noteAccessGranted()
            systemData.noteAccessGranted()
        }
        hasProbedAccess = true
    }
}
