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
            if installed != false, let blockReason {
                Text(blockReason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let run = model.runs[command.id] {
                RunResult(run: run)
            }
        }
    }

    private var installed: Bool? { model.isInstalled(command) }

    private var isRunning: Bool { model.running.contains(command.id) }

    private var displayTitle: String { title ?? String(localized: command.rule.title) }

    @ViewBuilder
    private var trailing: some View {
        if isRunning {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Running \(displayTitle)")
        } else if installed == false {
            Text("Not installed")
                .foregroundStyle(.secondary)
        } else {
            Button("Run…") {
                pending = .command(command, title: displayTitle)
            }
            .disabled(installed != true || blockReason != nil || model.isBusy)
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
