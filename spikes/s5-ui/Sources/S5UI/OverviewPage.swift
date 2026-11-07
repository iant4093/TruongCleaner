import Charts
import SwiftUI

struct OverviewPage: View {
    var body: some View {
        Form {
            Section {
                PageHeader(
                    symbol: "internaldrive.fill",
                    color: .gray,
                    title: FakeData.volumeName,
                    subtitle: "\(sizeText(FakeData.usedGB)) of \(sizeText(FakeData.totalGB)) used · "
                        + "\(sizeText(FakeData.availableGB)) available"
                )
                StorageBar()
            }

            Section("Recommendations") {
                ForEach(FakeData.recommendations) { item in
                    HStack(spacing: 10) {
                        IconTile(symbol: item.symbol, color: item.color)
                        Text(item.text)
                        Spacer()
                        Button("Review…") {}
                    }
                }
            }

            Section("Storage details") {
                LabeledContent("Purgeable") {
                    HStack(spacing: 6) {
                        Text(sizeText(12.0))
                        InfoButton(text: "Space macOS can free on its own when an app needs it. "
                            + "Calculated as available space for important usage minus plain available space.")
                    }
                }
                LabeledContent("Local snapshots") {
                    HStack(spacing: 6) {
                        Text("7 · size unknown")
                        InfoButton(text: "Time Machine keeps local snapshots on this Mac. "
                            + "macOS does not tell apps how big they are. macOS removes them when it needs space.")
                    }
                }
                LabeledContent("Unexplained") {
                    HStack(spacing: 6) {
                        Text(sizeText(23.4))
                        InfoButton(text: "Used space minus everything TruongCleaner measured. "
                            + "System files, protected data and other users' files can hide here. "
                            + "macOS does not say which.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Stacked storage bar (Swift Charts `BarMark`) with a legend, like Storage settings.
struct StorageBar: View {
    private static let colors: KeyValuePairs<String, Color> = [
        "Apps": .blue,
        "Documents": .orange,
        "Developer": .indigo,
        "Caches": .teal,
        "iOS Backups": .green,
        "System": .gray,
        "Unexplained": .pink,
        "Free": Color.secondary.opacity(0.15),
    ]

    var body: some View {
        Chart(FakeData.segments) { segment in
            BarMark(
                x: .value("Size (GB)", segment.gigabytes),
                y: .value("Volume", FakeData.volumeName),
                height: .ratio(1)
            )
            .foregroundStyle(by: .value("Category", segment.name))
        }
        .chartForegroundStyleScale(Self.colors)
        .chartXScale(domain: 0...FakeData.totalGB)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { plot in
            plot
                .frame(height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
        .frame(height: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage by category")
        .accessibilityValue(
            FakeData.segments
                .map { "\($0.name) \(spokenSize($0.gigabytes))" }
                .joined(separator: ", ")
        )
    }
}
