import enum CleanerCore.Category
import struct CleanerCore.Rule
import SwiftUI

/// Turn whole categories or single rules off (REQ-RULE-05).
struct RulesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.settings

        Form {
            Section {
                ForEach(settings.categories, id: \.self) { category in
                    DisclosureGroup {
                        ForEach(settings.rules(in: category)) { rule in
                            Toggle(isOn: ruleBinding(rule)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.title)
                                    Group {
                                        if rule.tier == .info {
                                            Text("Shown for information only. Nothing is removed.")
                                        } else {
                                            Text(rule.explain)
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } label: {
                        Toggle(category.settingsTitle, isOn: categoryBinding(category))
                    }
                }
            } footer: {
                Text("Rules that are off are skipped by scans and cleans.")
            }
        }
        .formStyle(.grouped)
    }

    private func ruleBinding(_ rule: Rule) -> Binding<Bool> {
        let settings = model.settings
        return Binding(
            get: { settings.isEnabled(rule) },
            set: { settings.setEnabled($0, for: rule) }
        )
    }

    private func categoryBinding(_ category: CleanerCore.Category) -> Binding<Bool> {
        let settings = model.settings
        return Binding(
            get: { settings.isCategoryEnabled(category) },
            set: { settings.setCategory(category, enabled: $0) }
        )
    }
}

private extension CleanerCore.Category {
    /// Plain name for the Rules tab.
    var settingsTitle: String {
        switch self {
        case .caches: "Caches"
        case .logs: "Logs and crash reports"
        case .trash: "Trash"
        case .browsers: "Browsers"
        case .apps: "App caches"
        case .developer: "Developer"
        case .mail: "Mail and Messages"
        case .ios: "iPhone and iPad"
        case .installers: "Installers and downloads"
        case .system: "System Data"
        }
    }
}
