import CleanerActions
import CleanerCore
import SwiftUI

/// What an uninstall did: counts, skipped items with their reasons, and Put Back.
///
/// There is no "delete for good" here: items stay in the Trash until the user empties it.
struct UninstallResultSheet: View {
    private struct SkippedGroup: Identifiable {
        let reason: String
        let items: [ItemReport]
        var id: String { reason }
    }

    /// Most names listed under one heading.
    private static let listLimit = 50

    let model: ApplicationsModel
    let report: CleanReport

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    PageHeader(
                        symbol: report.removedCount > 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                        color: report.removedCount > 0 ? .green : .orange,
                        title: headline,
                        subtitle: subtitle)
                }
                spaceSection
                countsSection
                if model.movedALaunchAgent {
                    Section {
                        Label(
                            "A launch agent was moved. It stays loaded until you log out or restart.",
                            systemImage: "info.circle")
                    }
                }
                skippedSection
                failedSection
                followUpSection
            }
            .formStyle(.grouped)

            Divider()
            buttons.padding(16)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 440, idealHeight: 540)
        .interactiveDismissDisabled(model.isWorking)
    }

    // MARK: Text

    private var appName: String {
        model.selectedRow?.facts.title ?? "the app"
    }

    private var headline: String {
        report.removedCount > 0
            ? "Moved \(itemsText(report.movedCount)) to the Trash"
            : "Nothing was removed"
    }

    private var subtitle: String {
        report.removedCount > 0
            ? "You can put these items back while they are in the Trash."
            : "\(appName) was not changed."
    }

    // MARK: Sections

    private var spaceSection: some View {
        Section {
            LabeledContent("Estimated to free") {
                SizeText(bytes: report.estimatedFreedBytes, isEstimate: true)
            }
        } footer: {
            if report.movedCount > 0 {
                Text("Items in the Trash still use space until the Trash is emptied.")
            }
        }
    }

    private var countsSection: some View {
        Section("Result") {
            LabeledContent("Moved to the Trash", value: report.movedCount.formatted())
            LabeledContent("Skipped", value: report.skippedItems.count.formatted())
            LabeledContent("Failed", value: report.failedItems.count.formatted())
        }
    }

    @ViewBuilder
    private var skippedSection: some View {
        let groups = Dictionary(grouping: report.skippedItems, by: { $0.reason.userMessage })
            .map { SkippedGroup(reason: $0.key, items: $0.value.map(\.item)) }
            .sorted { ($0.items.count, $1.reason) > ($1.items.count, $0.reason) }
        if !groups.isEmpty {
            Section("Skipped") {
                ForEach(groups) { group in
                    DisclosureGroup {
                        ForEach(group.items.prefix(Self.listLimit), id: \.findingID) { item in
                            HStack {
                                Text(item.originalPath.lastPathComponent)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(item.originalPath.path(percentEncoded: false))
                                Spacer(minLength: 8)
                                SizeText(bytes: item.estimatedBytes)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if group.items.count > Self.listLimit {
                            Text("and \((group.items.count - Self.listLimit).formatted()) more")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        HStack {
                            Text(group.reason)
                            Spacer()
                            Text(group.items.count.formatted()).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var failedSection: some View {
        let failed = report.failedItems
        if !failed.isEmpty {
            Section("Failed") {
                ForEach(failed.prefix(Self.listLimit), id: \.item.findingID) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.item.originalPath.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(entry.message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private var followUpSection: some View {
        if !model.followUpNotes.isEmpty {
            Section("Since then") {
                ForEach(Array(model.followUpNotes.enumerated()), id: \.offset) { _, note in
                    Text(note)
                }
            }
        }
    }

    // MARK: Buttons

    private var canPutBack: Bool {
        report.items.contains { item in
            if case .moved = item.outcome { !model.restoredFindingIDs.contains(item.findingID) } else { false }
        }
    }

    private var buttons: some View {
        HStack {
            if model.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }
            Spacer()
            if report.movedCount > 0 {
                Button("Put Back") {
                    Task { await model.putBackAll() }
                }
                .disabled(model.isWorking || !canPutBack)
                .help("Move the app and its files back to where they were")
            }
            Button("Done") { model.dismissResult() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isWorking)
        }
    }
}
