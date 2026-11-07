import SwiftUI

/// One grouped form (⌘,) to compare with a system Settings window.
struct SettingsView: View {
    enum DeleteMode: String, CaseIterable, Identifiable {
        case trash = "Move to Trash"
        case permanent = "Delete Permanently"
        var id: String { rawValue }
    }

    @State private var deleteMode = DeleteMode.trash
    @State private var checkForUpdates = true
    @State private var cachesOn = true
    @State private var logsOn = true
    @State private var developerOn = true

    var body: some View {
        Form {
            Section("Cleaning") {
                Picker("When cleaning", selection: $deleteMode) {
                    ForEach(DeleteMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Check for updates once a day", isOn: $checkForUpdates)
            }

            Section("Rules") {
                Toggle("Caches", isOn: $cachesOn)
                Toggle("Logs and crash reports", isOn: $logsOn)
                Toggle("Developer tools", isOn: $developerOn)
            }

            Section("Permissions") {
                LabeledContent("Full Disk Access") {
                    HStack(spacing: 8) {
                        Text("Not granted").foregroundStyle(.secondary)
                        Button("Open Privacy Settings…") {}
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}
