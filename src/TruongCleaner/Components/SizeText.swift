import CleanerCore
import SwiftUI

/// A byte count in Finder style (`ByteFormatter`), with digits that do not jump and a spoken label.
struct SizeText: View {
    let bytes: Int64
    /// Adds "about " in front. Use it for estimates.
    var isEstimate = false
    /// Shows "Unknown" instead of a number. A size that could not be measured is not zero.
    var isUnknown = false

    var body: some View {
        Text(visibleText)
            .monospacedDigit()
            .accessibilityLabel(spokenText)
    }

    private var visibleText: String {
        if isUnknown { return "Unknown" }
        let size = ByteFormatter.string(bytes)
        return isEstimate ? "about \(size)" : size
    }

    private var spokenText: String {
        if isUnknown { return "Size unknown" }
        let size = Self.spoken(bytes)
        return isEstimate ? "about \(size)" : size
    }

    /// The size written out for VoiceOver, such as "12.4 gigabytes".
    static func spoken(_ bytes: Int64) -> String {
        let value = Double(bytes)
        let steps: [(unit: UnitInformationStorage, size: Double)] = [
            (.terabytes, 1e12), (.gigabytes, 1e9), (.megabytes, 1e6), (.kilobytes, 1e3),
        ]
        let style = Measurement<UnitInformationStorage>.FormatStyle(
            width: .wide, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1)))
        for step in steps where abs(value) >= step.size {
            return Measurement(value: value / step.size, unit: step.unit).formatted(style)
        }
        return Measurement(value: value, unit: UnitInformationStorage.bytes).formatted(style)
    }
}
