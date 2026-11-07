import CleanerActions
import CleanerCore
import SwiftUI

/// History (`docs/UI.md` §4.7): every clean, what happened to each item, and Put Back.
struct HistoryPage: View {
    @Bindable var model: HistoryModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                symbol: Page.history.symbol,
                color: Page.history.color,
                title: Page.history.title,
                subtitle: Page.history.subtitle
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Divider()
            content
        }
        .task { await model.appeared() }
    }

    @ViewBuilder
    private var content: some View {
        if model.cleans.isEmpty {
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading history")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = model.message, message.isError {
                ContentUnavailableView(
                    "History Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message.text)
                )
            } else {
                ContentUnavailableView(
                    "No Cleans Yet",
                    systemImage: Page.history.symbol,
                    description: Text("When you clean, each item is listed here, so you can see what happened and put items back.")
                )
            }
        } else {
            VSplitView {
                cleanList
                    .frame(minHeight: 120, idealHeight: 180)
                details
                    .frame(minHeight: 200)
            }
        }
    }

    // MARK: Cleans

    private var cleanList: some View {
        List(model.cleans, selection: $model.selection) { clean in
            CleanRow(clean: clean)
                .tag(clean.id)
        }
        .accessibilityLabel("Cleans, newest first")
    }

    // MARK: Items

    private var details: some View {
        VStack(spacing: 0) {
            if let clean = model.selectedClean {
                detailHeader(clean)
                Divider()
                if model.rows.isEmpty {
                    ContentUnavailableView(
                        "No Items Recorded",
                        systemImage: "tray",
                        description: Text(
                            clean.isFinished
                                ? "This clean did not list any items."
                                : "The app stopped before this clean wrote its items."
                        )
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    itemsTable
                }
                if let message = model.message {
                    Divider()
                    Label(message.text, systemImage: message.isError ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(message.isError ? Color.orange : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .accessibilityElement(children: .combine)
                }
            } else {
                Color.clear
            }
        }
        .task(id: model.selection) { await model.loadItems() }
    }

    private func detailHeader(_ clean: CleanSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(clean.startedAt.formatted(date: .complete, time: .shortened))
                    .font(.headline)
                Text(clean.countsText)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            let count = model.puttableRows.count
            Button(count > 0 ? "Put Back All (\(count))" : "Put Back All") {
                Task { await model.putBackAll() }
            }
            .disabled(count == 0 || model.isPuttingBack)
            .help(count == 0 ? "No item of this clean can be put back" : "Move every item back to where it came from")
            .accessibilityLabel("Put back all items of this clean")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var itemsTable: some View {
        Table(model.rows) {
            TableColumn("Name") { row in
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 120, ideal: 180)

            TableColumn("Original Location") { row in
                Text(row.location)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
                    .help(row.report.originalPath.path)
            }
            .width(min: 120, ideal: 200)

            TableColumn("Size") { row in
                Text(ByteFormatter.string(row.bytes)).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            .alignment(.numeric)

            TableColumn("Outcome") { row in
                Text(model.outcomeText(for: row))
                    .lineLimit(2)
                    .help(model.outcomeText(for: row))
            }
            .width(min: 160, ideal: 260)

            TableColumn("") { row in
                putBackButton(row)
            }
            .width(min: 90, ideal: 100)
        }
        .accessibilityLabel("Items of the selected clean")
    }

    @ViewBuilder
    private func putBackButton(_ row: HistoryItemRow) -> some View {
        if case .notApplicable = row.putBackState {
            EmptyView()
        } else {
            let reason = model.disabledReason(for: row)
            Button("Put Back") {
                Task { await model.putBack(row) }
            }
            .disabled(reason != nil)
            .help(reason ?? "Move \(row.name) back to where it came from")
            .accessibilityLabel("Put back \(row.name)")
            .accessibilityHint(reason ?? "")
        }
    }
}

/// One clean in the list: date, mode, counts, and the estimate beside the measured change.
private struct CleanRow: View {
    let clean: CleanSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(clean.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.headline)
                    Text(clean.modeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Text(clean.countsText)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(clean.estimateText)
                    .monospacedDigit()
                    .help("Estimated space freed: what only these items used, not shared with copies")
                if let measured = clean.measuredText {
                    Text("Free space \(measured)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("Measured change in available space. Items in the Trash still use space until it is emptied.")
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
