import SwiftUI

/// Values to tune while comparing with System Settings. Change here only.
struct PrototypeTuning: Sendable {
    /// Sidebar and list-row tile edge length, in points.
    var tileSize: CGFloat = 24
    /// Corner radius at `tileSize`. Larger tiles scale it proportionally.
    var cornerRadius: CGFloat = 6
    /// Symbol point size at `tileSize`. Larger tiles scale it proportionally.
    var symbolSize: CGFloat = 13
    /// Tile edge length in page headers.
    var headerTileSize: CGFloat = 64

    static let standard = PrototypeTuning()
}

/// Colored rounded-square icon tile as drawn by System Settings (docs/UI.md §3.1).
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = PrototypeTuning.standard.tileSize

    var body: some View {
        let tuning = PrototypeTuning.standard
        let scale = size / tuning.tileSize
        Image(systemName: symbol)
            .font(.system(size: tuning.symbolSize * scale, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                color.gradient,
                in: RoundedRectangle(cornerRadius: tuning.cornerRadius * scale, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// Top-of-page group: large tile, title, one line of secondary text.
struct PageHeader: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 16) {
            IconTile(symbol: symbol, color: color, size: PrototypeTuning.standard.headerTileSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold())
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The (i) button that opens a popover explaining a number.
struct InfoButton: View {
    let text: String
    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel("About this number")
        .popover(isPresented: $isShown, arrowEdge: .trailing) {
            Text(text)
                .font(.callout)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
        }
    }
}

/// Glass for the floating bar. Swaps to a solid fill when Reduce Transparency is on.
/// Launch with `-forceReduceTransparency YES` to test the fallback without changing the system setting.
struct FloatingGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var systemReduce
    @AppStorage("forceReduceTransparency") private var forced = false

    func body(content: Content) -> some View {
        if systemReduce || forced {
            content
                .background(.background, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
        } else {
            content.glassEffect(.regular, in: .capsule)
        }
    }
}

/// Floating clean bar: summary pill plus the Clean button, inside one `GlassEffectContainer`.
struct CleanBar: View {
    let summary: String
    let canClean: Bool

    @Environment(\.accessibilityReduceTransparency) private var systemReduce
    @AppStorage("forceReduceTransparency") private var forced = false

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Text(summary)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .modifier(FloatingGlass())
                cleanButton
            }
        }
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var cleanButton: some View {
        if systemReduce || forced {
            Button("Clean") {}
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(!canClean)
        } else {
            Button("Clean") {}
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!canClean)
        }
    }
}

/// Size text in Finder style (`ByteCountFormatStyle`, file units).
func sizeText(_ gigabytes: Double) -> String {
    Int64(gigabytes * 1_000_000_000).formatted(.byteCount(style: .file))
}

/// Size text spelled out for VoiceOver ("12.4 gigabytes").
func spokenSize(_ gigabytes: Double) -> String {
    sizeText(gigabytes)
        .replacingOccurrences(of: " GB", with: " gigabytes")
        .replacingOccurrences(of: " MB", with: " megabytes")
        .replacingOccurrences(of: " KB", with: " kilobytes")
}
