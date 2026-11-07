import CleanerActions
import SwiftUI

/// Something on the Developer page that needs the user's confirmation before it runs.
enum DeveloperAction: Identifiable {
    case command(DeveloperCommand, title: String)
    case device(SimulatorDeviceRow)
    case runtime(SimulatorRuntimeRow)

    var id: String {
        switch self {
        case .command(let command, _): "command:\(command.id)"
        case .device(let device): "device:\(device.udid)"
        case .runtime(let runtime): "runtime:\(runtime.identifier)"
        }
    }
}

extension DeveloperAction {
    /// The title, button and message of the confirmation. The wording lives in `DeveloperConfirmation`.
    @MainActor
    func confirmation(in model: DeveloperModel) -> DeveloperConfirmation {
        switch self {
        case .command(let command, let title):
            .command(title: title, commandText: model.commandText(command))
        case .device(let device):
            .device(name: device.name, udid: device.udid, approximateBytes: Self.bytes(device.size))
        case .runtime(let runtime):
            .runtime(name: runtime.name, identifier: runtime.identifier, approximateBytes: runtime.bytes)
        }
    }

    private static func bytes(_ size: MeasuredSize) -> Int64? {
        if case .bytes(let bytes) = size { bytes } else { nil }
    }
}

/// A rule that a command-line tool carries out itself: title, what it does, a Run button, and after a run
/// the exit code and the tail of the output.
struct DeveloperCommandRow: View {
    let command: DeveloperCommand
    let model: DeveloperModel
    /// Replaces the rule's title, for example "Delete Unavailable Simulators".
    var title: String?
    /// Why Run is off right now, or `nil`.
    var blockReason: String?
    @Binding var pending: DeveloperAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    if let title {
                        Text(title)
                    } else {
                        Text(command.rule.title)
                    }
                    Text(command.rule.explain)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                trailing
            }
            if let note = state.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let run = model.runs[command.id] {
                RunResult(run: run)
            }
        }
    }

    /// What the trailing side and the note show. The rules live in `DeveloperRowState`.
    private var state: DeveloperRowState {
        DeveloperRowState(
            isInstalled: model.isInstalled(command), isRunning: model.running.contains(command.id),
            isBusy: model.isBusy, blockReason: blockReason)
    }

    private var displayTitle: String { title ?? String(localized: command.rule.title) }

    @ViewBuilder
    private var trailing: some View {
        switch state.trailing {
        case .running:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Running \(displayTitle)")
        case .notInstalled:
            Text(DeveloperRowState.notInstalledText)
                .foregroundStyle(.secondary)
        case .run(let isEnabled):
            Button("Run…") {
                pending = .command(command, title: displayTitle)
            }
            .disabled(!isEnabled)
            .accessibilityLabel("Run \(displayTitle)")
            .accessibilityHint("Asks you to confirm the exact command first")
        }
    }
}

/// What a command did: one line, and the output in a disclosure.
struct RunResult: View {
    let run: DeveloperCommandRun

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(run.summary)
            } icon: {
                Image(systemName: run.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(run.succeeded ? .green : .orange)
            }
            .font(.callout)
            if !run.output.isEmpty {
                DisclosureGroup("Output") {
                    ScrollView {
                        Text(run.output)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .font(.callout)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
