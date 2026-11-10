import SwiftUI

/// Colored rounded-square icon tile as drawn by System Settings (`docs/UI.md` §3.1).
///
/// Designed at 24 pt. Other sizes scale the corner radius and the symbol in proportion.
///
/// Every symbol is fitted into the same centered square box, so wide symbols (`memorychip`),
/// tall ones (`doc.fill`) and off-center ones (`magnifyingglass`) look the same size and sit in
/// the middle of the tile. Sizing by font point size alone made them uneven.
struct IconTile: View {
    /// Edge length used in the sidebar and list rows.
    static let standardSize: CGFloat = 24
    /// Edge length used in page headers.
    static let headerSize: CGFloat = 64

    /// Corner radius as a share of the edge (System Settings tiles: about 22.5%).
    private static let cornerRatio: CGFloat = 0.225
    /// The glyph box as a share of the edge.
    private static let glyphRatio: CGFloat = 0.58

    let symbol: String
    let color: Color
    var size: CGFloat = IconTile.standardSize

    var body: some View {
        let glyph = (size * Self.glyphRatio).rounded()
        RoundedRectangle(cornerRadius: size * Self.cornerRatio, style: .continuous)
            .fill(color.gradient)
            .overlay {
                RoundedRectangle(cornerRadius: size * Self.cornerRatio, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
            .overlay {
                Image(systemName: symbol)
                    .resizable()
                    .symbolRenderingMode(.monochrome)
                    .fontWeight(.semibold)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.white)
                    .frame(width: glyph, height: glyph)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
