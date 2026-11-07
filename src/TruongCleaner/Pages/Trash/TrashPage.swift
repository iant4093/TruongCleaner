import CleanerCore
import SwiftUI

/// Trash (`docs/UI.md` §4.7): its size, the items TruongCleaner put there, and the two ways to free them.
struct TrashPage: View {
    @Bindable var model: TrashModel

    var body: some View {
        Form {
            Section {
                PageHeader(
                    symbol: Page.trash.symbol,
                    color: Page.trash.color,
                    title: Page.trash.title,
                    subtitle: Page.trash.subtitle
                )
            }
            trashSection
            ourItemsSection
            if model.activity != .idle { progressSection }
            if let result = model.result { resultSection(result) }
        }
        .formStyle(.grouped)
        .task { await model.refresh() }
        .confirmationDialog(
            "Free space now?",
            isPresented: confirming(.freeSpace),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) { run { await model.freeSpaceNow() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This deletes for good up to \(model.ours?.count ?? 0) items, about \(ourBytesText), "
                    + "that TruongCleaner moved to the Trash. Everything else in the Trash stays. "
                    + "This cannot be undone."
            )
        }
        .confirmationDialog(
            "Empty the Trash?",
            isPresented: confirming(.emptyFirst),
            titleVisibility: .visible
        ) {
            Button("Continue…", role: .destructive) { model.confirmation = .emptySecond }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "\(model.snapshot?.itemCount ?? 0) items, about \(trashBytesText), will be deleted for good. "
                    + "TruongCleaner will ask once more."
            )
        }
        .confirmationDialog(
            "Delete about \(trashBytesText) for good?",
            isPresented: confirming(.emptySecond),
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) { run { await model.emptyTrash() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything in the Trash is deleted and cannot be put back. Items that are in use are left alone.")
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var trashSection: some View {
        Section("In the Trash") {
            switch model.state {
            case .loading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Reading the Trash…").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
            case .loaded(let snapshot):
                LabeledContent("Size", value: sizeText(snapshot))
                LabeledContent("Items", value: itemsText(snapshot))
                if snapshot.needsAccess {
                    TrashNeedsAccessRow { await model.refresh() }
                }
                if snapshot.partial {
                    Text("The Trash was only read in part, so these numbers are incomplete.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Empty Trash…") { model.confirmation = .emptyFirst }
                    .disabled(model.emptyDisabledReason != nil)
                    .help(model.emptyDisabledReason ?? "Delete everything in the Trash for good")
                    .accessibilityLabel("Empty the Trash")
                    .accessibilityHint(model.emptyDisabledReason ?? "Asks twice before deleting")
            }
        }
    }

    private var ourItemsSection: some View {
        Section("TruongCleaner items in the Trash") {
            if let ours = model.ours {
                LabeledContent("Items", value: "Up to \(ours.count)")
                LabeledContent("Size", value: "About \(ByteFormatter.string(ours.bytes))")
            } else {
                Label("History could not be read.", systemImage: "exclamationmark.triangle")
            }
            Text(
                "These are items TruongCleaner moved here, as History records them. "
                    + "Items you already emptied are skipped. Other files in the Trash are not touched."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Free Space Now") { model.confirmation = .freeSpace }
                    .disabled(model.freeSpaceDisabledReason != nil)
                    .help(model.freeSpaceDisabledReason ?? "Delete only the items TruongCleaner moved here, for good")
                    .accessibilityHint(model.freeSpaceDisabledReason ?? "Asks before deleting")
            }
        }
    }

    private var progressSection: some View {
        Section {
            HStack {
                ProgressView().controlSize(.small)
                Text(model.activity == .emptying ? "Emptying the Trash…" : "Freeing space…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func resultSection(_ result: TrashActionResult) -> some View {
        Section("Last action") {
            Label(result.title, systemImage: result.isError ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(result.isError ? Color.orange : Color.primary)
            ForEach(result.lines, id: \.self) { line in
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Text

    private func sizeText(_ snapshot: TrashSnapshot) -> String {
        if snapshot.needsAccess {
            // Never show a denied folder as zero.
            return snapshot.findings.isEmpty ? "Unknown" : "At least \(ByteFormatter.string(snapshot.allocatedBytes))"
        }
        return snapshot.itemCount == 0 ? "Empty" : "About \(ByteFormatter.string(snapshot.allocatedBytes))"
    }

    private func itemsText(_ snapshot: TrashSnapshot) -> String {
        if snapshot.needsAccess { return snapshot.findings.isEmpty ? "Unknown" : "At least \(snapshot.itemCount)" }
        return "\(snapshot.itemCount)"
    }

    private var trashBytesText: String {
        ByteFormatter.string(model.snapshot?.allocatedBytes ?? 0)
    }

    private var ourBytesText: String {
        ByteFormatter.string(model.ours?.bytes ?? 0)
    }

    // MARK: Helpers

    /// A binding that is on while `confirmation` is the open dialog. Moving to the next dialog
    /// inside a button is not undone when the first one closes.
    private func confirming(_ step: TrashModel.Confirmation) -> Binding<Bool> {
        Binding(
            get: { model.confirmation == step },
            set: { isOn in
                if !isOn, model.confirmation == step { model.confirmation = nil }
            }
        )
    }

    private func run(_ action: @escaping () async -> Void) {
        Task { await action() }
    }
}

/// "Needs Full Disk Access" with a lock and a button that opens the Privacy pane.
private struct TrashNeedsAccessRow: View {
    let checkAgain: () async -> Void
    @SwiftUI.Environment(\.openURL) private var openURL
    @State private var showFallbackHint = false

    private static let privacyPane = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Needs Full Disk Access", systemImage: "lock.fill")
                Spacer()
                Button("Open Privacy Settings") { open() }
                Button("Check Again") { Task { await checkAgain() } }
            }
            Text("macOS does not let TruongCleaner read the Trash yet, so its size is unknown, not zero.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if showFallbackHint {
                Text("Open System Settings, then Privacy & Security, then Full Disk Access, and turn on TruongCleaner.")
                    .font(.callout)
            }
        }
    }

    private func open() {
        guard let url = Self.privacyPane else {
            showFallbackHint = true
            return
        }
        openURL(url) { accepted in
            if !accepted { showFallbackHint = true }
        }
    }
}
