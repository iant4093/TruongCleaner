import CleanerScanner
import SwiftUI

extension SystemDataValue {
    /// The value spelled out for VoiceOver.
    @MainActor
    var spoken: String {
        switch self {
        case .size(let bytes): SpokenSize.string(bytes)
        case .atLeast(let bytes): "At least \(SpokenSize.string(bytes))"
        default: display
        }
    }
}

/// One contributor in the System Data list, as an `ItemRow`: tile, name, what it is, an Info or Needs access
/// badge, size, and one action. A row with a second action (Open Settings and Copy Command) puts it in the
/// ellipsis menu.
struct SystemDataRowView: View {
    let row: SystemDataRow

    @State private var showsCommand = false
    @State private var showsDetails = false

    var body: some View {
        itemRow
    }

    private var itemRow: ItemRow {
        var item = ItemRow(
            icon: ItemRowIcon(symbol: row.symbol, color: row.color),
            title: row.title,
            explain: row.explain,
            note: row.note,
            size: size
        )
        .badge(row.value == .needsAccess ? .needsAccess : .info)
        .trailing {
            actions
        }
        if let snapshots = row.snapshots {
            item = item.disclosure {
                ForEach(snapshots, id: \.name) { snapshot in
                    Text(snapshot.date?.formatted(date: .abbreviated, time: .shortened) ?? snapshot.name)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        return item
    }

    private var size: ItemRowSize {
        switch row.value {
        case .size(let bytes): .bytes(bytes)
        case .atLeast(let bytes): .atLeast(bytes)
        case .text(let text): .text(text)
        case .macOSOnly: .text("macOS only")
        case .unknown, .needsAccess: .unknown
        }
    }

    /// Open Settings, Copy Command, or Learn More. Rows with a settings pane and a command show the pane as
    /// the button and the command in the menu.
    private var actions: some View {
        ItemRowActions(actions: actionList)
            .popover(isPresented: $showsCommand, arrowEdge: .leading) {
                CommandPopover(command: row.command ?? "")
            }
            .popover(isPresented: $showsDetails, arrowEdge: .leading) {
                Text(row.explain + "\n\nTruongCleaner shows this number only. It cannot remove it.")
                    .font(.callout)
                    .frame(width: 280, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
            }
    }

    private var actionList: [ItemRowAction] {
        var list: [ItemRowAction] = []
        if let url = row.settingsURL {
            list.append(
                ItemRowAction(title: "Open Settings", accessibilityLabel: "Open Settings for \(row.title)") {
                    SystemDataActions.open(url)
                })
        }
        if let command = row.command {
            list.append(
                ItemRowAction(title: "Copy Command", accessibilityLabel: "Copy Command for \(row.title)") {
                    SystemDataActions.copy(command)
                    showsCommand = true
                })
        }
        if list.isEmpty {
            list.append(
                ItemRowAction(title: "Learn More", accessibilityLabel: "Learn more about \(row.title)") {
                    showsDetails = true
                })
        }
        return list
    }
}

/// Shows the copied command and says it needs an administrator. The app never runs it.
private struct CommandPopover: View {
    let command: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Copied to the clipboard", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.semibold))
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("Needs your administrator password. Run it in Terminal. TruongCleaner does not run it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 300, alignment: .leading)
        .padding(14)
    }
}
