import SwiftUI

/// System Data page (docs/UI.md §4.3): Info rows with a trailing action.
struct SystemDataPage: View {
    var body: some View {
        Form {
            Section {
                PageHeader(
                    symbol: "gearshape.2.fill",
                    color: .gray,
                    title: "System Data",
                    subtitle: "Space that macOS manages. We explain it and show the Apple-approved fix."
                )
                LabeledContent("Measured") {
                    Text("\(sizeText(437.0)) of \(sizeText(FakeData.usedGB)) used")
                }
                LabeledContent("Unexplained") {
                    HStack(spacing: 6) {
                        Text(sizeText(23.4))
                        InfoButton(text: "Used space minus everything TruongCleaner measured. "
                            + "macOS does not tell apps what else is on the disk.")
                    }
                }
            }

            Section("What is in System Data") {
                ForEach(FakeData.systemRows) { row in
                    SystemDataRow(row: row)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SystemDataRow: View {
    let row: SystemRow

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: row.symbol, color: row.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                Text(row.explain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                if row.needsAccess {
                    Label(row.value, systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else {
                    Text(row.value).monospacedDigit()
                }
                Text(row.tier.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(row.action) {}
        }
    }
}
