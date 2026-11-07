import CleanerCore
import CleanerScanner
import Observation
import SwiftUI

/// What the Overview page shows once the disk has been read.
struct OverviewData {
    /// How many local snapshots `tmutil` listed, or that the list could not be read.
    enum SnapshotSummary {
        case count(Int)
        case unavailable
    }

    let volume: VolumeInfo
    let volumeName: String
    let snapshots: SnapshotSummary
    let swap: SwapUsage?
    let segments: [StorageSegment]

    /// "X of Y used · Z available". Used = capacity minus plain available space.
    var subtitle: String {
        "\(ByteFormatter.string(volume.containerUsed)) of \(ByteFormatter.string(volume.total)) used · "
            + "\(ByteFormatter.string(volume.available)) available"
    }

    var purgeableText: String { ByteFormatter.string(volume.purgeable) }

    var importantAvailableText: String { ByteFormatter.string(volume.availableForImportantUsage) }

    var swapText: String {
        swap.map { ByteFormatter.string($0.used) } ?? "Unknown"
    }

    /// macOS does not report snapshot sizes, so the count is shown with that note.
    var snapshotsText: String {
        switch snapshots {
        case .count(0): "None"
        case .count(let count): "\(count) · size unknown"
        case .unavailable: "Unknown"
        }
    }
}

/// Loads the startup disk numbers for the Overview page. Reads happen off the main actor.
@Observable @MainActor
final class OverviewModel {
    enum State {
        case loading
        case loaded(OverviewData)
        case failed(String)
    }

    /// Fallback when no System volume name is known.
    static let fallbackVolumeName = "Macintosh HD"
    /// Automatic refreshes (appear, app becomes active) are skipped inside this window.
    static let minimumRefreshInterval: Duration = .seconds(30)

    private(set) var state: State = .loading

    @ObservationIgnored private var lastLoad: ContinuousClock.Instant?
    @ObservationIgnored private var isRefreshing = false

    /// Refreshes unless a refresh is running or the last one finished less than 30 s ago.
    func refreshIfNeeded() async {
        if let lastLoad, lastLoad.duration(to: .now) < Self.minimumRefreshInterval { return }
        await refresh()
    }

    /// Reads volume, snapshot and swap numbers concurrently and updates ``state``.
    ///
    /// Earlier data stays on screen while the new numbers load. A cancelled refresh
    /// changes nothing, so the next appearance loads again.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let volume = VolumeInfo.current()
        async let snapshots = Snapshots.list()
        async let swap = Self.readSwap()
        let (volumeResult, snapshotResult, swapResult) = await (volume, snapshots, swap)
        guard !Task.isCancelled else { return }

        lastLoad = .now
        guard volumeResult.total > 0 else {
            state = .failed("TruongCleaner could not read the size of the startup disk.")
            return
        }
        let summary: OverviewData.SnapshotSummary = switch snapshotResult {
        case .success(let list): .count(list.count)
        case .failure: .unavailable
        }
        state = .loaded(OverviewData(
            volume: volumeResult,
            volumeName: Self.volumeName(for: volumeResult),
            snapshots: summary,
            swap: swapResult,
            segments: Self.segments(for: volumeResult)
        ))
    }

    @concurrent
    private static func readSwap() async -> SwapUsage? {
        SwapProbe.current()
    }

    // MARK: Formatting logic

    /// APFS roles that belong to macOS itself rather than to the user's Data volume.
    private static let systemRoles: Set<String> = ["System", "Preboot", "Recovery", "VM", "Update"]

    /// Name of the System volume, which is what Finder calls the startup disk.
    static func volumeName(for volume: VolumeInfo) -> String {
        volume.volumes.first { $0.roles.contains("System") }?.name ?? fallbackVolumeName
    }

    /// Bar parts that add up to the disk capacity: macOS volumes, Data, other volumes, purgeable, free.
    ///
    /// Purgeable space lives inside the Data volume, so it is taken out of Data. Without
    /// per-volume numbers the bar shows a single "Used" part instead.
    static func segments(for volume: VolumeInfo) -> [StorageSegment] {
        let purgeable = volume.purgeable
        let free = StorageSegment(label: "Free", bytes: volume.available, color: .secondary.opacity(0.25))
        let purgeableSegment = StorageSegment(label: "Purgeable", bytes: purgeable, color: .orange)

        guard !volume.volumes.isEmpty else {
            let used = StorageSegment(label: "Used", bytes: max(0, volume.containerUsed - purgeable), color: .blue)
            return [used, purgeableSegment, free]
        }

        let macOS = volume.volumes
            .filter { !systemRoles.isDisjoint(with: $0.roles) }
            .reduce(Int64(0)) { $0 + $1.bytesUsed }
        let data = volume.volumes
            .filter { $0.roles.contains("Data") }
            .reduce(Int64(0)) { $0 + $1.bytesUsed }
        let other = max(0, volume.containerUsed - macOS - data)

        return [
            StorageSegment(label: "Used by macOS volumes", bytes: macOS, color: .gray),
            StorageSegment(label: "Data", bytes: max(0, data - purgeable), color: .blue),
            StorageSegment(label: "Other volumes", bytes: other, color: .teal),
            purgeableSegment,
            free,
        ]
    }
}
