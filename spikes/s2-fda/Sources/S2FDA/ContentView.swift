import AppKit
import SwiftUI

struct ContentView: View {
    let model: ProbeModel

    var body: some View {
        Form {
            verdictSection
            probesSection
            actionsSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 760, minHeight: 520)
        .task { model.run() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.run()
        }
    }

    private var verdictSection: some View {
        Section {
            LabeledContent("Full Disk Access") {
                if let report = model.report {
                    Label(title(for: report.verdict), systemImage: symbol(for: report.verdict))
                        .foregroundStyle(color(for: report.verdict))
                        .accessibilityLabel("Full Disk Access verdict: \(title(for: report.verdict))")
                } else {
                    Text("Checking…").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Last run") {
                HStack(spacing: 8) {
                    if model.isRunning { ProgressView().controlSize(.small) }
                    Text(model.report.map { $0.date.formatted(date: .omitted, time: .standard) } ?? "Not yet")
                        .monospacedDigit()
                }
            }
        } footer: {
            Text("granted: Safari, Mail, Messages or Stocks is readable. "
                + "notGranted: every one that exists returns EPERM or EACCES. Otherwise unknown. "
                + "Probes re-run when this app becomes active.")
        }
    }

    private var probesSection: some View {
        Section("Probes") {
            if let report = model.report {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("Path")
                        Text("Method")
                        Text("Result")
                        Text("ms").gridColumnAlignment(.trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Divider()
                    ForEach(report.results) { result in
                        GridRow {
                            Text(result.displayPath)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Text(result.method)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(result.resultText)
                                .font(.callout)
                                .foregroundStyle(color(for: result.outcome))
                                .textSelection(.enabled)
                            Text(String(format: "%.2f", result.milliseconds))
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } else {
                ProgressView("Running probes…")
            }
        }
    }

    private var actionsSection: some View {
        Section {
            HStack {
                Button("Run Again") { model.run() }
                    .disabled(model.isRunning)
                Button("Open Full Disk Access Settings") {
                    model.open(ProbeModel.fullDiskAccessURL)
                }
                Button("Open Privacy & Security") {
                    model.open(ProbeModel.privacyURL)
                }
                Button("Copy Results") { model.copyResults() }
                    .disabled(model.report == nil)
            }
            if let status = model.openStatus {
                Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let status = model.copyStatus {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func title(for verdict: FDAVerdict) -> String {
        switch verdict {
        case .granted: "granted"
        case .notGranted: "notGranted"
        case .unknown: "unknown"
        }
    }

    private func symbol(for verdict: FDAVerdict) -> String {
        switch verdict {
        case .granted: "checkmark.circle.fill"
        case .notGranted: "xmark.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    private func color(for verdict: FDAVerdict) -> Color {
        switch verdict {
        case .granted: .green
        case .notGranted: .red
        case .unknown: .orange
        }
    }

    private func color(for outcome: ProbeOutcome) -> Color {
        if outcome == .readable { return .green }
        return outcome.isDenied ? .red : .secondary
    }
}
