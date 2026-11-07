import Charts
import CleanerCore
import SwiftUI

/// One colored part of a ``StorageBar``.
struct StorageSegment: Identifiable {
    /// Name shown in the legend. Unique within one bar.
    let label: String
    /// Size in bytes. Segments of zero bytes are not drawn.
    let bytes: Int64
    let color: Color

    var id: String { label }
}

/// Stacked storage bar (Swift Charts `BarMark`) with a legend of dots and sizes, like Storage settings.
///
/// The bar takes any list of segments, so later waves can split "Data" into categories
/// without changing this view.
struct StorageBar: View {
    /// Parts in drawing order, left to right.
    let segments: [StorageSegment]
    /// Value the whole bar stands for. Usually the disk capacity.
    let total: Int64

    private static let barHeight: CGFloat = 22

    private var visibleSegments: [StorageSegment] {
        segments.filter { $0.bytes > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart(visibleSegments) { segment in
                BarMark(
                    x: .value("Size", segment.bytes),
                    y: .value("Volume", "Startup disk"),
                    height: .ratio(1)
                )
                .foregroundStyle(by: .value("Category", segment.label))
            }
            .chartForegroundStyleScale(
                domain: visibleSegments.map(\.label),
                range: visibleSegments.map(\.color)
            )
            .chartXScale(domain: 0...max(total, 1))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartPlotStyle { plot in
                plot
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .frame(height: Self.barHeight)

            legend
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage by category")
        .accessibilityValue(spokenSummary)
    }

    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(visibleSegments) { segment in
                HStack(spacing: 6) {
                    Circle()
                        .fill(segment.color)
                        .frame(width: 8, height: 8)
                    Text(segment.label)
                        .lineLimit(1)
                    Text(ByteFormatter.string(segment.bytes))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    /// "macOS 11 gigabytes, Data 84 gigabytes, ..." for VoiceOver.
    private var spokenSummary: String {
        visibleSegments
            .map { "\($0.label) \(SpokenSize.string($0.bytes))" }
            .formatted(.list(type: .and, width: .standard))
    }
}

/// Byte counts spelled out for VoiceOver ("12.4 gigabytes").
enum SpokenSize {
    static func string(_ bytes: Int64) -> String {
        let value = Double(bytes)
        let (unit, divisor): (UnitInformationStorage, Double) = switch bytes {
        case 1_000_000_000_000...: (.terabytes, 1_000_000_000_000)
        case 1_000_000_000...: (.gigabytes, 1_000_000_000)
        case 1_000_000...: (.megabytes, 1_000_000)
        case 1_000...: (.kilobytes, 1_000)
        default: (.bytes, 1)
        }
        return Measurement(value: value / divisor, unit: unit)
            .formatted(.measurement(width: .wide, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }
}
