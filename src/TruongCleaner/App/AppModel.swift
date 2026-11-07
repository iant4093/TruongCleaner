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
}
