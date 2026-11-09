import SwiftUI

@main
struct TruongCleanerApp: App {
    @State private var model: AppModel
    private let launch: LaunchOptions

    init() {
        let launch = LaunchOptions()
        let model = AppModel()
        if let page = launch.page { model.selection = page }
        self.launch = launch
        self.model = model
        // Tidy up after an earlier in-app update (old app to the Trash, stale temp folders).
        Task { await UpdateChecker.removeLeftovers() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .modifier(ActivationChecks(model: model))
                .modifier(LaunchActions(model: model, launch: launch))
        }
        .defaultSize(width: launch.windowSize?.width ?? 900, height: launch.windowSize?.height ?? 620)
        .commands { WelcomeCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .modifier(ActivationChecks(model: model))
        }
    }
}

/// Probes Full Disk Access whenever the scene becomes active (REQ-PERM-03), and checks for a
/// newer build when one is due (at most once a day, only if the user allows it).
private struct ActivationChecks: ViewModifier {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.refreshAccess()
            await model.updates.checkIfDue()
        }
    }
}

/// Help > Welcome to TruongCleaner shows the welcome sheet again.
private struct WelcomeCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Welcome to TruongCleaner") {
                model.isOnboardingPresented = true
            }
        }
    }
}

/// Optional launch arguments, used to stage the README screenshots. Without them the app starts
/// as usual. They only choose a page, start a scan and size the window; none of them cleans.
///
/// - `-TCStartPage <overview|smartClean|systemData|developer|largeFiles|spaceLens|trash|history|settings>`
/// - `-TCAutoScan YES`: start the page's scan once it appears (scan only, never clean).
/// - `-TCLensRoot <folder>`: the folder Space Lens explores (with `-TCAutoScan YES`).
/// - `-TCWindowSize <width>x<height>`: default size of the main window.
private struct LaunchOptions {
    /// The page to select, or `nil` for the default. `settings` is handled by ``opensSettings``.
    let page: Page?
    let opensSettings: Bool
    let autoScan: Bool
    let lensRoot: URL?
    let windowSize: CGSize?

    init(defaults: UserDefaults = .standard) {
        let name = defaults.string(forKey: "TCStartPage")
        page = name.flatMap { Page(rawValue: $0) }
        opensSettings = name == "settings"
        autoScan = defaults.bool(forKey: "TCAutoScan")
        lensRoot = defaults.string(forKey: "TCLensRoot").map { URL(filePath: $0, directoryHint: .isDirectory) }
        let parts = defaults.string(forKey: "TCWindowSize")?.split(separator: "x").compactMap { Double($0) }
        if let parts, parts.count == 2, parts[0] >= 760, parts[1] >= 520 {
            windowSize = CGSize(width: parts[0], height: parts[1])
        } else {
            windowSize = nil
        }
    }
}

/// Carries out ``LaunchOptions`` once, when the main window first appears.
private struct LaunchActions: ViewModifier {
    let model: AppModel
    let launch: LaunchOptions
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.task {
            if launch.opensSettings { openSettings() }
            guard launch.autoScan else { return }
            if model.selection == .spaceLens, let root = launch.lensRoot {
                model.spaceLens.choose(root)
                return
            }
            // System Data loads when its page appears. The other pages are ready a moment after launch.
            guard model.selection != .systemData else { return }
            for _ in 0..<30 {
                if let scan = model.toolbarScan, scan.isEnabled, !scan.isRunning {
                    scan.perform()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
