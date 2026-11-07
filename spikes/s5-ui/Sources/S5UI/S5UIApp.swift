import SwiftUI

@main
struct S5UIApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 900, height: 620)

        Settings {
            SettingsView()
        }
    }
}
