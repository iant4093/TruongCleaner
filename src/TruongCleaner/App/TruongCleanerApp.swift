import SwiftUI

@main
struct TruongCleanerApp: App {
    @State private var model: AppModel

    init() {
        model = AppModel()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .modifier(ActivationChecks(model: model))
        }
        .defaultSize(width: 900, height: 620)
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
