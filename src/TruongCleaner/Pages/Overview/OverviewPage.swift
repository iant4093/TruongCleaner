import SwiftUI

/// Startup disk overview, modeled on System Settings > Storage (`docs/UI.md` §4.1).
struct OverviewPage: View {
    let model: OverviewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
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
                subtitle: data.subtitle
            )
            StorageBar(segments: data.segments, total: data.volume.total)
        }

        Section("Storage details") {
            detailRow(
                "Purgeable",
                value: data.purgeableText,
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
                info: "Disk space macOS uses when memory runs short. The number comes from the "
                    + "system. Quitting apps that use a lot of memory, or restarting, reduces it."
            )
            detailRow(
                "Available for important data",
                value: data.importantAvailableText,
                info: "Free space plus purgeable space. This is the amount Finder and System Settings "
                    + "show as available. It comes from the volume's capacity values."
            )
        }
    }

    private func detailRow(_ title: String, value: String, info: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(value)
                InfoButton(subject: title, text: info)
            }
        }
    }

    private var recommendations: some View {
        Section("Recommendations") {
            HStack(spacing: 10) {
                IconTile(symbol: Page.smartClean.symbol, color: Page.smartClean.color)
                Text("Run Smart Clean to see what can be freed")
                Spacer()
                Button("Review…") {}
                    .disabled(true)
            }
        }
    }
}
