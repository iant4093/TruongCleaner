import enum CleanerCore.ByteFormatter
import SwiftUI

// The chart is drawn with `Canvas`, not Swift Charts. `SectorMark` stacks all of a chart's marks around one
// circle, so three concentric rings that stay aligned with their parents would need three overlaid charts, each
// with filler marks for the gaps. Canvas draws every slice from the layout directly, and hit testing is plain
// polar math against the same numbers.

/// Sizes and radii of the sunburst for a given view size.
struct SunburstGeometry: Equatable {
    let center: CGPoint
    let centerRadius: CGFloat
    let ringThickness: CGFloat
    let outerRadius: CGFloat

    init(size: CGSize) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        outerRadius = max(0, min(size.width, size.height) / 2 - 4)
        centerRadius = outerRadius * 0.3
        ringThickness = (outerRadius - centerRadius) / CGFloat(SunburstLayout.ringCount)
    }

    /// The ring (1-based) and the clockwise fraction of a turn from 12 o'clock at `point`, or `nil` in the center
    /// circle and outside the chart.
    func locate(_ point: CGPoint) -> (ring: Int, fraction: Double)? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let radius = (dx * dx + dy * dy).squareRoot()
        guard ringThickness > 0, radius >= centerRadius, radius < outerRadius else { return nil }
        let ring = min(SunburstLayout.ringCount, Int((radius - centerRadius) / ringThickness) + 1)
        var angle = atan2(Double(dx), Double(-dy))
        if angle < 0 { angle += 2 * .pi }
        return (ring, angle / (2 * .pi))
    }

    /// The outline of a slice.
    func path(ring: Int, start: Double, end: Double) -> Path {
        let inner = centerRadius + ringThickness * CGFloat(ring - 1)
        let outer = inner + ringThickness
        let from = Angle.degrees(-90 + start * 360)
        let to = Angle.degrees(-90 + end * 360)
        var path = Path()
        // SwiftUI's y axis points down, so `clockwise: false` runs clockwise on screen.
        path.addArc(center: center, radius: outer, startAngle: from, endAngle: to, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: to, endAngle: from, clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// Concentric-ring size chart for one scanned folder (`docs/UI.md` §4.6).
///
/// Hover shows a label, a click on a folder slice opens it, and the center circle goes up one level.
struct SunburstView: View {
    let tree: LensTree
    let canGoUp: Bool
    let onExplore: (LensNode) -> Void
    let onGoUp: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            SunburstChart(tree: tree, canGoUp: canGoUp, onExplore: onExplore, onGoUp: onGoUp)
                .id(tree.id)
                .transition(.opacity)
        }
        // Reduce Motion: no cross-fade between levels.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: tree.id)
    }
}

private struct SunburstChart: View {
    let tree: LensTree
    let canGoUp: Bool
    let onExplore: (LensNode) -> Void
    let onGoUp: () -> Void

    @State private var hovered: SunburstLayout.Sector?
    @State private var pointer = CGPoint.zero

    var body: some View {
        GeometryReader { proxy in
            let geometry = SunburstGeometry(size: proxy.size)
            ZStack {
                SunburstRings(layout: tree.layout, geometry: geometry)
                    .equatable()
                SunburstHighlight(sector: hovered, geometry: geometry)
                    .allowsHitTesting(false)
                center(geometry)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    pointer = location
                    update(sector: sector(at: location, in: geometry))
                case .ended:
                    update(sector: nil)
                }
            }
            .onTapGesture { location in
                guard let node = sector(at: location, in: geometry)?.node, node.isExplorable else { return }
                onExplore(node)
            }
            .overlay(alignment: .topLeading) { tooltip(in: proxy.size, at: pointer, anchoredLeft: true) }
            .overlay(alignment: .topTrailing) { tooltip(in: proxy.size, at: pointer, anchoredLeft: false) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Size chart of \(tree.root.name). The list shows the same items.")
    }

    private func sector(at point: CGPoint, in geometry: SunburstGeometry) -> SunburstLayout.Sector? {
        guard let spot = geometry.locate(point) else { return nil }
        return tree.layout.sector(ring: spot.ring, fraction: spot.fraction)
    }

    /// Only writes when the slice changes, so moving inside one slice does not redraw anything but the label.
    private func update(sector: SunburstLayout.Sector?) {
        if hovered?.id != sector?.id { hovered = sector }
    }

    // MARK: Center

    @ViewBuilder
    private func center(_ geometry: SunburstGeometry) -> some View {
        let diameter = max(0, geometry.centerRadius * 2 - 6)
        if canGoUp {
            Button(action: onGoUp) {
                centerLabel(diameter: diameter, showsUpHint: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Go up one level")
            .accessibilityHint("Currently showing \(tree.root.name)")
        } else {
            centerLabel(diameter: diameter, showsUpHint: false)
                .accessibilityElement(children: .combine)
        }
    }

    private func centerLabel(diameter: CGFloat, showsUpHint: Bool) -> some View {
        VStack(spacing: 2) {
            if showsUpHint {
                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(tree.root.name)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            Text(ByteFormatter.string(tree.root.bytes))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(6)
        .frame(width: diameter, height: diameter)
        .background(.quaternary, in: Circle())
        .contentShape(Circle())
    }

    // MARK: Tooltip

    /// The label is drawn from the left edge when the pointer is in the left half and from the right edge
    /// otherwise, so it never runs off the chart. Only the matching overlay shows it.
    @ViewBuilder
    private func tooltip(in size: CGSize, at point: CGPoint, anchoredLeft: Bool) -> some View {
        if let hovered, (point.x <= size.width / 2) == anchoredLeft {
            SunburstTooltip(node: hovered.node, rootBytes: tree.root.bytes, rootName: tree.root.name)
                .offset(
                    x: anchoredLeft ? point.x + 14 : point.x - size.width - 14,
                    y: min(point.y + 14, max(0, size.height - 70))
                )
                .allowsHitTesting(false)
        }
    }
}

/// Every ring slice, drawn once. Redraws only when the tree or the size changes.
private struct SunburstRings: View, Equatable {
    let layout: SunburstLayout
    let geometry: SunburstGeometry

    static func == (left: Self, right: Self) -> Bool {
        left.layout === right.layout && left.geometry == right.geometry
    }

    var body: some View {
        Canvas { context, _ in
            for ring in layout.rings {
                for sector in ring {
                    let path = geometry.path(ring: sector.ring, start: sector.start, end: sector.end)
                    context.fill(path, with: .color(SunburstPalette.color(index: sector.paletteIndex, ring: sector.ring)))
                    context.stroke(path, with: .color(.primary.opacity(0.18)), lineWidth: 0.5)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A bright outline over the slice under the pointer.
private struct SunburstHighlight: View {
    let sector: SunburstLayout.Sector?
    let geometry: SunburstGeometry

    var body: some View {
        Canvas { context, _ in
            guard let sector else { return }
            let path = geometry.path(ring: sector.ring, start: sector.start, end: sector.end)
            context.fill(path, with: .color(.white.opacity(0.25)))
            context.stroke(path, with: .color(.primary.opacity(0.8)), lineWidth: 1.5)
        }
        .accessibilityHidden(true)
    }
}

private struct SunburstTooltip: View {
    let node: LensNode
    let rootBytes: Int64
    let rootName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(node.name)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
            Text(ByteFormatter.string(node.bytes))
            Text("\(shareText) of \(rootName)")
                .foregroundStyle(.secondary)
            if node.isExplorable {
                Text("Click to open")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 200, alignment: .leading)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
    }

    private var shareText: String {
        guard rootBytes > 0 else { return "0%" }
        let share = Double(node.bytes) / Double(rootBytes)
        return share < 0.01 ? "Less than 1%" : share.formatted(.percent.precision(.fractionLength(0)))
    }
}
