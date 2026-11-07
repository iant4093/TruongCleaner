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

/// One contributor in the System Data list: tile, name, what it is, size, tier and one action.
struct SystemDataRowView: View {
    let row: SystemDataRow

    @State private var showsCommand = false
    @State private var showsDetails = false

    var body: some View {
        if let snapshots = row.snapshots {
            DisclosureGroup {
                ForEach(snapshots, id: \.name) { snapshot in
                    Text(snapshot.date?.formatted(date: .abbreviated, time: .shortened) ?? snapshot.name)
                        .foregroundStyle(.secondary)
                }
            } label: {
                content
            }
        } else {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: row.symbol, color: row.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                Text(row.explain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = row.note {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                valueText
                tierLabel
            }
            actions
        }
    }

    @ViewBuilder
    private var valueText: some View {
        switch row.value {
        case .needsAccess:
            Label(row.value.display, systemImage: "lock.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(row.value.spoken)
        case .size, .atLeast:
            Text(row.value.display)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(row.value.spoken)
        case .text, .unknown, .macOSOnly:
            Text(row.value.display)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    /// Every row on this page is Info: it is shown, never removed by this app.
    private var tierLabel: some View {
        Text("Info")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .accessibilityLabel("Information only. TruongCleaner does not remove this.")
    }

    /// Open Settings, Copy Command, or Learn More. Rows with a settings pane and a command show both.
    private var actions: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let url = row.settingsURL {
                Button("Open Settings") { SystemDataActions.open(url) }
                    .accessibilityLabel("Open Settings for \(row.title)")
            }
            if let command = row.command {
                Button("Copy Command") {
                    SystemDataActions.copy(command)
                    showsCommand = true
                }
                .accessibilityLabel("Copy Command for \(row.title)")
                .popover(isPresented: $showsCommand, arrowEdge: .leading) {
                    CommandPopover(command: command)
                }
            }
            if row.settingsURL == nil, row.command == nil {
                Button("Learn More") { showsDetails = true }
                    .accessibilityLabel("Learn more about \(row.title)")
                    .popover(isPresented: $showsDetails, arrowEdge: .leading) {
                        Text(row.explain + "\n\nTruongCleaner shows this number only. It cannot remove it.")
                            .font(.callout)
                            .frame(width: 280, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                    }
            }
        }
        .controlSize(.small)
        .fixedSize()
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
