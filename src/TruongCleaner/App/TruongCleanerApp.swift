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
        }
        .defaultSize(width: 900, height: 620)

        Settings {
            Form {}
                .formStyle(.grouped)
                .frame(width: 450, height: 300)
        }
    }
}
