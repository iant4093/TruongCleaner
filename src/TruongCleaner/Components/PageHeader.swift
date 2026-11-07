import SwiftUI

/// Top-of-page group like System Settings: large tile, title, one line of secondary text.
struct PageHeader: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 16) {
            IconTile(symbol: symbol, color: color, size: IconTile.headerSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold())
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
