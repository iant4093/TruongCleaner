import SwiftUI

/// What macOS lumps into "System Data": every contributor with its size, what it is, and the one action we
/// offer (`docs/UI.md` §4.3). Rows only inform. Nothing here deletes.
struct SystemDataPage: View {
    let model: SystemDataModel
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Form {
            if let failure = model.failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                PageHeader(
                    symbol: Page.systemData.symbol,
                    color: Page.systemData.color,
                    title: Page.systemData.title,
                    subtitle: model.report?.summary ?? "Measuring…"
                )
                if let report = model.report {
                    if let used = report.dataVolumeUsed {
                        StorageBar(segments: report.segments, total: used)
                    }
                } else if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Measuring System Data")
                }
                HStack {
                    Button {
                        Task { await model.refresh(settings: appModel.settings, access: appModel.access) }
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isLoading)
                    if model.isLoading, model.report != nil {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Measuring System Data")
                    }
                }
            }

            if let report = model.report {
                ForEach(SystemDataSection.allCases) { section in
                    let rows = report.rows(in: section)
                    if !rows.isEmpty {
                        Section(section.title) {
                            ForEach(rows) { SystemDataRowView(row: $0) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Runs on appear and when Full Disk Access changes. The model skips a load that is still fresh.
        .task(id: appModel.access) {
            await model.loadIfNeeded(settings: appModel.settings, access: appModel.access)
        }
    }
}

extension SystemDataReport {
    /// Bar parts: purgeable space, each section's measured sizes, and the unexplained rest.
    @MainActor
    var segments: [StorageSegment] {
        let purgeableID = "system.purgeable"
        var result = [
            StorageSegment(
                label: "Purgeable",
                bytes: rows.first { $0.id == purgeableID }?.value.countedBytes ?? 0,
                color: .orange
            ),
        ]
        for section in SystemDataSection.allCases {
            let bytes = rows(in: section)
                .filter { $0.countsTowardUsed && $0.id != purgeableID }
                .reduce(Int64(0)) { $0 + ($1.value.countedBytes ?? 0) }
            result.append(StorageSegment(label: section.title, bytes: bytes, color: section.color))
        }
        result.append(StorageSegment(
            label: "Unexplained",
            bytes: unexplainedBytes ?? 0,
            color: .secondary.opacity(0.35)
        ))
        return result
    }
}
