import SwiftUI

/// Colored rounded-square icon tile as drawn by System Settings (`docs/UI.md` §3.1).
///
/// Designed at 24 pt. Other sizes scale the corner radius and the symbol in proportion.
struct IconTile: View {
    /// Edge length used in the sidebar and list rows.
    static let standardSize: CGFloat = 24
    /// Edge length used in page headers.
    static let headerSize: CGFloat = 64

    private static let cornerRadius: CGFloat = 6
    private static let symbolSize: CGFloat = 13

    let symbol: String
    let color: Color
    var size: CGFloat = IconTile.standardSize

    var body: some View {
        let scale = size / Self.standardSize
        Image(systemName: symbol)
            .font(.system(size: Self.symbolSize * scale, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                color.gradient,
                in: RoundedRectangle(cornerRadius: Self.cornerRadius * scale, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}
