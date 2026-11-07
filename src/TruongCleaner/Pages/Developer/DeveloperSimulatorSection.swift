import SwiftUI

/// Simulators (`docs/UI.md` §4.4): a table of devices, a table of runtimes, and the commands that delete them.
/// Every action asks first and names what it removes.
struct DeveloperSimulatorSection: View {
    /// Rows shown before a table scrolls.
    private static let visibleRows = 8
    private static let rowHeight: CGFloat = 26
    private static let headerHeight: CGFloat = 32

    let model: DeveloperModel
    @Binding var pending: DeveloperAction?

    var body: some View {
        Section {
            switch model.simulatorStatus {
            case .notLoaded, .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Reading simulators")
                    Text("Reading simulators…")
                        .foregroundStyle(.secondary)
                }
            case .unavailable(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            case .ready:
                deviceTable
                runtimeTable
            }

            if let command = model.command(DeveloperRuleIDs.simulatorCommand) {
                DeveloperCommandRow(
                    command: command, model: model, title: "Delete Unavailable Simulators",
                    blockReason: model.simulatorBlockReason, pending: $pending)
            }

            if let run = model.lastItemRun {
                RunResult(run: run)
            }
        } header: {
            Text("Simulators")
        } footer: {
            Text("Deleting a simulator removes its apps and data. Xcode can create new ones.")
        }
    }

    // MARK: Devices

    @ViewBuilder
    private var deviceTable: some View {
        Text("Devices")
            .font(.headline)
        if model.devices.isEmpty {
            Text("No simulators.")
                .foregroundStyle(.secondary)
        } else {
            Table(model.devices) {
                TableColumn("Name") { device in
                    Text(device.name)
                        .lineLimit(1)
                        .help(device.udid)
                }
                TableColumn("Runtime") { device in
                    Text(device.runtimeName)
                }
                .width(min: 70, ideal: 90)
                TableColumn("State") { device in
                    Text(device.isAvailable ? device.stateText : "\(device.stateText), unavailable")
                        .foregroundStyle(device.isShutDown ? Color.secondary : Color.primary)
                }
                .width(min: 70, ideal: 100)
                TableColumn("Last Used") { device in
                    Text(lastUsed(device.lastUsed))
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 100)
                TableColumn("Size") { device in
                    sizeCell(device.size)
                }
                .width(min: 70, ideal: 80)
                TableColumn("") { device in
                    deleteButton(device)
                }
                .width(min: 80, ideal: 90)
            }
            .frame(height: tableHeight(rows: model.devices.count))
            .accessibilityLabel("Simulator devices")
        }
    }

    private func deleteButton(_ device: SimulatorDeviceRow) -> some View {
        let reason = model.deleteBlockReason(device)
        return Button("Delete…") { pending = .device(device) }
            .disabled(reason != nil)
            .help(reason ?? "Delete \(device.name)")
            .accessibilityLabel("Delete simulator \(device.name), \(device.runtimeName)")
    }

    // MARK: Runtimes

    @ViewBuilder
    private var runtimeTable: some View {
        Text("Runtimes")
            .font(.headline)
        if let note = model.runtimeNote {
            Text(note)
                .foregroundStyle(.secondary)
        } else if model.runtimes.isEmpty {
            Text("No downloaded runtimes.")
                .foregroundStyle(.secondary)
        } else {
            Table(model.runtimes) {
                TableColumn("Name") { runtime in
                    Text(runtime.name)
                        .lineLimit(1)
                }
                TableColumn("Version") { runtime in
                    Text(runtime.version)
                }
                .width(min: 60, ideal: 80)
                TableColumn("Size") { runtime in
                    if let bytes = runtime.bytes {
                        SizeText(bytes: bytes)
                    } else {
                        SizeText(bytes: 0, isUnknown: true)
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 70, ideal: 80)
                TableColumn("Last Used") { runtime in
                    Text(lastUsed(runtime.lastUsed))
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 100)
                TableColumn("") { runtime in
                    deleteButton(runtime)
                }
                .width(min: 80, ideal: 90)
            }
            .frame(height: tableHeight(rows: model.runtimes.count))
            .accessibilityLabel("Simulator runtimes")
        }
    }

    private func deleteButton(_ runtime: SimulatorRuntimeRow) -> some View {
        let reason = model.deleteBlockReason(runtime)
        return Button("Delete…") { pending = .runtime(runtime) }
            .disabled(reason != nil)
            .help(reason ?? "Delete \(runtime.name)")
            .accessibilityLabel("Delete runtime \(runtime.name)")
    }

    // MARK: Cells

    @ViewBuilder
    private func sizeCell(_ size: MeasuredSize) -> some View {
        switch size {
        case .measuring:
            Text("Measuring…")
                .foregroundStyle(.secondary)
        case .bytes(let bytes):
            SizeText(bytes: bytes)
        case .unknown:
            SizeText(bytes: 0, isUnknown: true)
                .foregroundStyle(.secondary)
        }
    }

    private func lastUsed(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .omitted) ?? "Never"
    }

    private func tableHeight(rows: Int) -> CGFloat {
        CGFloat(min(rows, Self.visibleRows)) * Self.rowHeight + Self.headerHeight
    }
}
