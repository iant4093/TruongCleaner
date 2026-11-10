import CleanerActions
import CleanerCore
import SwiftUI

/// What a clean did (`docs/UI.md` §4.2): counts, the measured change in free space beside the
/// estimate, skipped items with their reasons, and the ways to finish or undo.
struct CleanResultSheet: View {
    /// Skipped items listed under one reason.
    private struct SkippedGroup: Identifiable {
        let reason: String
        let items: [ItemReport]
        var id: String { reason }
    }

    /// Most names listed under one heading.
    private static let listLimit = 50

    let model: SmartCleanModel
    let report: CleanReport
    @State private var showFreeSpaceConfirm = false
    @State private var showFreeSpaceSecondConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                headerSection
                spaceSection
                countsSection
                skippedSection
                failedSection
                followUpSection
            }
            .formStyle(.grouped)

            Divider()
            buttons
                .padding(16)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 460, idealHeight: 560)
        .interactiveDismissDisabled(model.isWorking)
        .confirmationDialog(
            "Delete the items TruongCleaner moved to the Trash?",
            isPresented: $showFreeSpaceConfirm,
            titleVisibility: .visible
        ) {
            Button("Continue…", role: .destructive) { showFreeSpaceSecondConfirm = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This deletes every item TruongCleaner moved to the Trash that is still there, "
                    + "from this clean and earlier ones. Anything else in the Trash is left alone. "
                    + "TruongCleaner will ask once more."
            )
        }
        .confirmationDialog(
            "Delete \(ourItemsText) for good?",
            isPresented: $showFreeSpaceSecondConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                Task { await model.freeSpaceNow() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Up to \(ourItemsText) that TruongCleaner moved to the Trash will be deleted, "
                    + "including items from earlier cleans, not only this one. "
                    + "They cannot be put back. Anything else in the Trash is left alone."
            )
        }
    }

    // MARK: Sections

    private var headerSection: some View {
        Section {
            PageHeader(
                symbol: report.removedCount > 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                color: report.removedCount > 0 ? .green : .orange,
                title: headline,
                subtitle: subtitle
            )
        }
    }

    private var headline: String {
        guard report.removedCount > 0 else { return "Nothing was removed" }
        switch report.mode {
        case .trash: return "Moved \(itemsText(report.movedCount)) to the Trash"
        case .permanent: return "Deleted \(itemsText(report.deletedCount))"
        }
    }

    private var subtitle: String {
        switch report.mode {
        case .trash: "You can put these items back while they are in the Trash."
        case .permanent: "Deleted items cannot be put back."
        }
    }

    private var spaceSection: some View {
        Section {
            LabeledContent("Estimated to free") {
                SizeText(bytes: report.estimatedFreedBytes, isEstimate: true)
            }
            LabeledContent("Change in available space") {
                Text(measuredText)
                    .monospacedDigit()
            }
        } footer: {
            if report.mode == .trash, report.movedCount > 0 {
                Text(
                    "Items in the Trash still use space until the Trash is emptied. "
                        + "Free Space Now deletes the items TruongCleaner moved, and only those."
                )
            }
        }
    }

    /// The measured change, in words. Moving to the Trash frees nothing yet, so zero is normal.
    private var measuredText: String {
        guard let change = report.measuredFreedBytes else { return "Could not be measured" }
        if change == 0 { return "No change" }
        let size = ByteFormatter.string(abs(change))
        return change > 0 ? "\(size) more available" : "\(size) less available"
    }

    private var countsSection: some View {
        Section("Result") {
            LabeledContent("Moved to the Trash", value: report.movedCount.formatted())
            LabeledContent("Deleted", value: report.deletedCount.formatted())
            LabeledContent("Skipped", value: report.skippedItems.count.formatted())
            LabeledContent("Failed", value: report.failedItems.count.formatted())
        }
    }

    @ViewBuilder
    private var skippedSection: some View {
        let groups = skippedGroups
        if !groups.isEmpty {
            Section("Skipped") {
                ForEach(groups) { group in
                    DisclosureGroup {
                        ForEach(group.items.prefix(Self.listLimit), id: \.findingID) { item in
                            itemLine(item)
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
                            Text(group.items.count.formatted())
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var skippedGroups: [SkippedGroup] {
        Dictionary(grouping: report.skippedItems, by: { $0.reason.displayMessage })
            .map { SkippedGroup(reason: $0.key, items: $0.value.map(\.item)) }
            .sorted { ($0.items.count, $1.reason) > ($1.items.count, $0.reason) }
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
                if failed.count > Self.listLimit {
                    Text("and \((failed.count - Self.listLimit).formatted()) more")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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

    private func itemLine(_ item: ItemReport) -> some View {
        HStack {
            Text(item.originalPath.lastPathComponent)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.originalPath.path)
            Spacer(minLength: 8)
            SizeText(bytes: item.estimatedBytes)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Buttons

    private var canPutBack: Bool {
        report.items.contains { model.canPutBack($0) }
    }

    /// "12 items, about 3 GB", from the history read just before the first dialog opened.
    private var ourItemsText: String {
        guard let items = model.ourTrashItems else { return "the items" }
        return "\(itemsText(items.count)), about \(ByteFormatter.string(items.bytes))"
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
                .help("Move the items from this clean back to where they were")

                Button("Free Space Now…") {
                    Task {
                        // Read what would be deleted first, so both dialogs can name the count and size.
                        if await model.readOurTrashItems() != nil { showFreeSpaceConfirm = true }
                    }
                }
                .disabled(model.isWorking)
                .help("Delete the items TruongCleaner moved to the Trash")
            }
            Button("Done") { model.dismissResult() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isWorking)
        }
    }
}
