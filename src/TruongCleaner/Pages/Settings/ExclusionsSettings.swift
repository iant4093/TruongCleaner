import SwiftUI

/// Folders TruongCleaner must never scan or clean (REQ-RULE-05).
struct ExclusionsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: URL?

    var body: some View {
        let settings = model.settings

        Form {
            if settings.exclusionsUnreadable {
                Section {
                    Text(
                        "The saved list of excluded folders could not be read, so scans and cleans "
                            + "are paused. Start a new list to continue."
                    )
                    Button("Start a New List") { settings.startNewExclusionList() }
                }
            }

            Section {
                if settings.exclusions.isEmpty {
                    Text("No folders excluded.")
                        .foregroundStyle(.secondary)
                } else {
                    List(settings.exclusions, id: \.self, selection: $selection) { url in
                        Label(url.path(percentEncoded: false), systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(url.path(percentEncoded: false))
                    }
                    .frame(minHeight: 140)
                }
                HStack {
                    Button("Add Folder…", systemImage: "plus") {
                        settings.addExclusions(SettingsActions.chooseFolders())
                    }
                    Button("Remove", systemImage: "minus") {
                        if let selection {
                            settings.removeExclusion(selection)
                            self.selection = nil
                        }
                    }
                    .disabled(selection == nil)
                }
                .disabled(settings.exclusionsUnreadable)
            } header: {
                Text("Excluded folders")
            } footer: {
                Text("TruongCleaner skips these folders and everything inside them.")
            }
        }
        .formStyle(.grouped)
    }
}
