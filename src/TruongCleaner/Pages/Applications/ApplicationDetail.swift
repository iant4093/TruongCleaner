import CleanerCore
import CleanerScanner
import SwiftUI

/// The inspector for the selected app: what goes with it, grouped by folder, and the Move to Trash bar.
struct ApplicationDetail: View {
    let model: ApplicationsModel
    /// Asks the page to show its confirmation dialog.
    let requestClean: () -> Void

    @SwiftUI.Environment(AppModel.self) private var app

    var body: some View {
        content
            .safeAreaInset(edge: .bottom) { bottomBar }
    }

    @ViewBuilder
    private var content: some View {
        switch model.detail {
        case .none:
            ContentUnavailableView(
                "Select an App", systemImage: "square.grid.2x2",
                description: Text("Choose an app in the list, or drop an app on this window."))
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Looking for files this app left behind…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .refused(let facts, let refusal):
            refusedForm(facts, refusal)
        case .ready(let report):
            readyForm(report)
        }
    }

    // MARK: Refused

    private func refusedForm(_ facts: AppFacts, _ refusal: UninstallRefusal) -> some View {
        Form {
            Section { header(facts, total: nil) }
            Section {
                Label(refusal.message, systemImage: "nosign")
                Text(Self.explanation(for: refusal))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private static func explanation(for refusal: UninstallRefusal) -> String {
        switch refusal {
        case .systemApp, .apple: "Apple’s apps are part of macOS. TruongCleaner does not remove them."
        case .signatureUnknown: "TruongCleaner could not read who signed this app, so it keeps it."
        case .thisApp: "TruongCleaner cannot remove itself. Drag it to the Trash in Finder."
        case .running: "Quit the app, then choose it again."
        case .runningUnknown: "TruongCleaner could not tell if this app is running, so it keeps it."
        case .noBundleID: "The app has no identifier, so there is nothing safe to match its files with."
        case .outsideApplicationFolders: "Only apps in /Applications or ~/Applications can be removed here."
        case .needsAdministrator: "An administrator owns this app. Remove it in Finder, which asks for a password."
        case .ownerUnknown: "TruongCleaner could not check who owns this app, so it keeps it."
        case .unreadable: "The app could not be read."
        }
    }

    // MARK: Ready

    private func readyForm(_ report: UninstallReport) -> some View {
        Form {
            Section { header(report.app, total: model.selectedBytes) }

            Section("Application") {
                bundleRow(report)
            }

            ForEach(groups(of: report)) { group in
                Section(group.place.title) {
                    ForEach(group.items) { leftover in
                        LeftoverRow(
                            leftover: leftover,
                            isOn: Binding(
                                get: { model.isChecked(leftover) },
                                set: { model.setChecked($0, for: leftover) }))
                    }
                }
            }

            if report.leftovers.isEmpty {
                Section {
                    Text("No files in your Library were matched to this app.")
                        .foregroundStyle(.secondary)
                }
            }

            if !report.systemItems.isEmpty {
                Section {
                    ForEach(report.systemItems) { item in
                        SystemItemRow(item: item)
                    }
                } header: {
                    Text("Needs an administrator")
                } footer: {
                    Text("These are shown for your information. TruongCleaner does not change /Library.")
                }
            }

            ForEach(report.unreadablePlaces, id: \.place) { unreadable in
                Section {
                    NeedsAccessRow(
                        kind: unreadable.needsAccess
                            ? (app.access == .granted ? .refusedByMacOS : .fullDiskAccess) : .refusedByMacOS,
                        openPrivacySettings: SmartCleanActions.openPrivacySettings)
                } header: {
                    Text(unreadable.place.title)
                }
            }

            if report.unmeasuredCount > 0 {
                Section {
                    Label(
                        "\(itemsText(report.unmeasuredCount)) could not be read, so they are not listed.",
                        systemImage: "lock.fill")
                }
            }

            if let notice = report.notice {
                Section {
                    Label(notice, systemImage: "info.circle")
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isCleaning)
    }

    private struct PlaceGroup: Identifiable {
        let place: LeftoverPlace
        let items: [Leftover]
        var id: LeftoverPlace { place }
    }

    private func groups(of report: UninstallReport) -> [PlaceGroup] {
        LeftoverPlace.all.compactMap { place in
            let items = report.leftovers.filter { $0.place == place }
            return items.isEmpty ? nil : PlaceGroup(place: place, items: items)
        }
    }

    private func header(_ facts: AppFacts, total: Int64?) -> some View {
        HStack(spacing: 12) {
            FileIcon(url: facts.url, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(facts.title).font(.title3.bold())
                if let version = facts.version {
                    Text("Version \(version)").foregroundStyle(.secondary)
                }
                if let total {
                    HStack(spacing: 4) {
                        Text("Moves about")
                        SizeText(bytes: total)
                        Text("to the Trash")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func bundleRow(_ report: UninstallReport) -> some View {
        HStack(spacing: 10) {
            FileIcon(url: report.app.url)
            VStack(alignment: .leading, spacing: 1) {
                Text(report.app.url.lastPathComponent)
                Text(report.app.url.deletingLastPathComponent().path(percentEncoded: false))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            SizeText(bytes: report.bundle.allocatedBytes, isEstimate: report.bundleSizeIsAtLeast)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button("Reveal in Finder") { SmartCleanActions.reveal(report.app.url) }
        }
    }

    // MARK: Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        switch model.cleanState {
        case .idle, .finished:
            if model.report != nil {
                CleanBar(
                    summary: CleanBarText.summary(bytes: model.selectedBytes, itemCount: model.selectedItemCount, mode: .trash),
                    detail: CleanBarText.detail(itemCount: model.selectedItemCount, privateBytes: model.selectedPrivateBytes),
                    canClean: model.canClean,
                    action: requestClean)
            }
        case .cleaning(let progress):
            CleanProgressBar(done: progress?.done ?? 0, total: progress?.total ?? 0)
        }
    }
}

/// One leftover: checkbox, icon, name, why it belongs to the app, and its size.
private struct LeftoverRow: View {
    let leftover: Leftover
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $isOn) {
                HStack(spacing: 8) {
                    FileIcon(url: leftover.finding.url)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(leftover.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(leftover.evidence.text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel("\(leftover.name), \(SizeText.spoken(leftover.finding.allocatedBytes))")
            .accessibilityHint(leftover.evidence.text)
            Spacer(minLength: 8)
            if leftover.tier == .review {
                Text("Review")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SizeText(bytes: leftover.finding.allocatedBytes, isEstimate: leftover.sizeIsAtLeast)
                .foregroundStyle(.secondary)
        }
        .help(leftover.finding.url.path(percentEncoded: false))
        .contextMenu {
            Button("Reveal in Finder") { SmartCleanActions.reveal(leftover.finding.url) }
        }
    }
}

/// An item in `/Library`: shown, never selectable.
private struct SystemItemRow: View {
    let item: SystemLeftover

    var body: some View {
        HStack(spacing: 8) {
            FileIcon(url: item.url)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(item.place.title). \(item.evidence.text)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let bytes = item.allocatedBytes {
                SizeText(bytes: bytes).foregroundStyle(.secondary)
            } else {
                SizeText(bytes: 0, isUnknown: true).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .help(item.url.path(percentEncoded: false))
    }
}
