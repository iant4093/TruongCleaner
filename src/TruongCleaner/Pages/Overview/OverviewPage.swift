import SwiftUI

/// Startup disk overview, modeled on System Settings > Storage (`docs/UI.md` §4.1).
struct OverviewPage: View {
    let model: OverviewModel
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase

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
            StorageBar(segments: data.segments, total: data.volume.total)
        }

        Section("Storage details") {
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
