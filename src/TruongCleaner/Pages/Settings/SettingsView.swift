import SwiftUI

/// The Settings window (⌘,): General, Exclusions, Rules and Permissions (`docs/UI.md` §4.8).
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Exclusions", systemImage: "minus.circle") { ExclusionsSettings() }
            Tab("Rules", systemImage: "checklist") { RulesSettings() }
            Tab("Permissions", systemImage: "lock.shield") { PermissionsSettings() }
        }
        .frame(width: 540, height: 460)
    }
}
