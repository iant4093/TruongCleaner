import CleanerCore
import SwiftUI

/// Startup disk overview, modeled on System Settings > Storage (`docs/UI.md` §4.1).
struct OverviewPage: View {
    let model: OverviewModel
    @SwiftUI.Environment(AppModel.self) private var appModel
    @SwiftUI.Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            if let release = appModel.updates.available {
                Section { UpdateBanner(release: release, onDismiss: appModel.updates.dismiss) }
            }
            switch model.state {
            case .loading:
                Section {
                    PageHeader(
                        symbol: Page.overview.symbol,
                        color: Page.overview.color,
                        title: OverviewModel.fallbackVolumeName,
                        subtitle: "Reading disk information…"
                    )
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Reading disk information")
                }
            case .failed(let message):
                Section {
                    PageHeader(
                        symbol: Page.overview.symbol,
                        color: Page.overview.color,
                        title: OverviewModel.fallbackVolumeName,
                        subtitle: message
                    )
                    Button("Try Again") {
                        Task { await model.refresh() }
                    }
                }
            case .loaded(let data):
                loadedSections(data)
            }

            recommendations
        }
        .formStyle(.grouped)
        // Runs on appear and whenever the app becomes active or inactive. Throttled in the model.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.refreshIfNeeded()
        }
    }

    @ViewBuilder
    private func loadedSections(_ data: OverviewData) -> some View {
        Section {
            PageHeader(
                symbol: Page.overview.symbol,
                color: Page.overview.color,
                title: data.volumeName,
                subtitle: data.subtitle,
                spokenSubtitle: data.spokenSubtitle
            )
            StorageBar(
                segments: OverviewModel.segments(for: data.volume, categories: appModel.categories.totals),
                total: data.volume.total
            )
            categoryStatus
        }

        Section("Storage details") {
            if let systemData = OverviewModel.systemDataBytes(for: data.volume, categories: appModel.categories.totals) {
                detailRow(
                    "System Data",
                    value: ByteFormatter.string(systemData),
                    spoken: SpokenSize.string(systemData),
                    info: "What is left of the Data volume after purgeable space and the folders "
                        + "TruongCleaner measured: apps, documents, caches, developer data, mail and "
                        + "the rest of your home folder. It holds macOS files, local snapshots, other "
                        + "users' hidden data and space shared between cloned copies of files. "
                        + "Sizes in the bar count the space each folder holds on its own, so cloned "
                        + "data that two copies share is not in any of them."
                )
            }
            detailRow(
                "Purgeable",
                value: data.purgeableText,
                spoken: SpokenSize.string(data.volume.purgeable),
                info: "Space macOS frees on its own when an app needs room, such as caches and "
                    + "local snapshots. TruongCleaner works it out as the space available for "
                    + "important files minus the space available right now."
            )
            detailRow(
                "Local snapshots",
                value: data.snapshotsText,
                info: "Time Machine keeps snapshots of this Mac on the disk. macOS does not say how "
                    + "much space they use, and removes them when it needs room. The count comes "
                    + "from the tmutil tool."
            )
            detailRow(
                "Swap in use",
                value: data.swapText,
                spoken: data.swap.map { SpokenSize.string($0.used) },
                info: "Disk space macOS uses when memory runs short. The number comes from the "
                    + "system. Quitting apps that use a lot of memory, or restarting, reduces it."
            )
            detailRow(
                "Available for important data",
                value: data.importantAvailableText,
                spoken: SpokenSize.string(data.volume.availableForImportantUsage),
                info: "Free space plus purgeable space. This is the amount Finder and System Settings "
                    + "show as available. It comes from the volume's capacity values."
            )
        }
    }

    /// A small note under the bar: measuring progress, or why some sizes are missing.
    @ViewBuilder
    private var categoryStatus: some View {
        let categories = appModel.categories
        if categories.isMeasuring {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Measuring your files")
                Text("Measuring your files…")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Stop") { categories.cancel() }
                    .controlSize(.small)
                    .accessibilityHint("Stops measuring and keeps the previous sizes")
            }
            .font(.callout)
        } else if categories.totals == nil {
            HStack(spacing: 8) {
                Text("Data is one block until your files are measured.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Break Down Data") { categories.start(force: false) }
                    .controlSize(.small)
                    .accessibilityHint("Measures apps, documents, caches and developer files. Takes about 20 seconds.")
            }
            .font(.callout)
        } else if let totals = categories.totals, totals.totalNeedsAccess > 0 {
            Label(
                "Some folders need Full Disk Access, so their sizes are missing from the bar. "
                    + "Their size is counted in System Data.",
                systemImage: "lock.fill"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func detailRow(_ title: String, value: String, spoken: String? = nil, info: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(value)
                    .accessibilityLabel(spoken ?? value)
                InfoButton(subject: title, text: info)
            }
        }
    }

    private var recommendations: some View {
        let snapshots: OverviewData.SnapshotSummary? = if case .loaded(let data) = model.state {
            data.snapshots
        } else {
            nil
        }
        return Section("Recommendations") {
            ForEach(RecommendationBuilder.build(smartClean: appModel.smartClean, snapshots: snapshots)) { item in
                HStack(spacing: 10) {
                    IconTile(symbol: item.symbol, color: item.color)
                    Text(item.text)
                        .accessibilityLabel(item.spokenText)
                    Spacer(minLength: 8)
                    Button(item.buttonTitle) { perform(item.action) }
                        .accessibilityLabel(item.buttonLabel)
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    private func perform(_ action: Recommendation.Action) {
        switch action {
        case .open(let page):
            appModel.selection = page
        case .startSmartClean:
            // The user pressed the button. Nothing here runs by itself.
            appModel.smartClean.scan()
            appModel.selection = .smartClean
        }
    }
}
