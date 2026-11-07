import Foundation
import SwiftUI

/// Where every slice of the sunburst sits, as fractions of a full turn.
///
/// Angles run clockwise from 12 o'clock. Ring 1 is the lens root's children, ring 2 their children, ring 3 the
/// next level. A slice narrower than half a degree is merged into its parent's "Other" slice, and an "Other"
/// slice that is still narrower than that is not drawn, so a ring never holds more than 720 slices.
nonisolated final class SunburstLayout: Sendable {
    /// Number of rings around the center.
    static let ringCount = 3
    /// Narrowest slice that is drawn, as a fraction of a full turn (0.5°).
    static let minimumSpan = 0.5 / 360

    /// One drawn slice.
    nonisolated struct Sector: Sendable, Identifiable {
        let id: Int
        /// 1 for the innermost ring.
        let ring: Int
        /// Start and end as fractions of a full turn, clockwise from 12 o'clock.
        let start: Double
        let end: Double
        let node: LensNode
        /// Index into ``SunburstPalette``; `nil` draws a neutral gray.
        let paletteIndex: Int?
    }

    /// Slices per ring, index 0 = ring 1. Each ring is sorted by `start`.
    let rings: [[Sector]]

    /// Lays out `root`'s descendants down to three rings.
    init(root: LensNode) {
        var builder = Placer()
        builder.place(root.children, parentBytes: root.bytes, start: 0, span: 1, ring: 1, paletteIndex: nil)
        rings = builder.rings
    }

    /// Number of slices over all rings.
    var sectorCount: Int { rings.reduce(0) { $0 + $1.count } }

    /// The slice at `fraction` of a turn in `ring` (1-based), or `nil` for a gap.
    func sector(ring: Int, fraction: Double) -> Sector? {
        guard ring >= 1, ring <= rings.count else { return nil }
        let sectors = rings[ring - 1]
        // Last slice that starts at or before the fraction.
        var low = 0
        var high = sectors.count
        while low < high {
            let middle = (low + high) / 2
            if sectors[middle].start <= fraction { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        let candidate = sectors[low - 1]
        return fraction < candidate.end ? candidate : nil
    }

    private struct Placer {
        var rings = [[Sector]](repeating: [], count: SunburstLayout.ringCount)
        private var nextID = 0

        mutating func place(
            _ children: [LensNode], parentBytes: Int64, start: Double, span: Double, ring: Int, paletteIndex: Int?
        ) {
            guard ring <= SunburstLayout.ringCount, parentBytes > 0, !children.isEmpty else { return }
            // Children can add up to a little more than the parent when hard-linked data moved between folders.
            let total = children.reduce(Int64(0)) { $0 + $1.bytes }
            let denominator = Double(max(parentBytes, total))
            var cursor = start
            var emitted = 0
            var pooledBytes: Int64 = 0
            var pooledCount = 0

            for child in children where child.bytes > 0 {
                let childSpan = span * Double(child.bytes) / denominator
                if child.kind == .other || childSpan < SunburstLayout.minimumSpan {
                    pooledBytes += child.bytes
                    pooledCount += child.itemCount
                    continue
                }
                let index = ring == 1 ? emitted % SunburstPalette.count : paletteIndex
                emitted += 1
                append(child, ring: ring, start: cursor, span: childSpan, paletteIndex: index)
                place(
                    child.children, parentBytes: child.bytes, start: cursor, span: childSpan, ring: ring + 1,
                    paletteIndex: index)
                cursor += childSpan
            }

            let pooledSpan = span * Double(pooledBytes) / denominator
            if pooledSpan >= SunburstLayout.minimumSpan {
                let other = LensNode(
                    id: -1 - nextID, url: nil, name: "Other", bytes: pooledBytes, kind: .other, isDenied: false,
                    itemCount: pooledCount, children: [])
                append(other, ring: ring, start: cursor, span: pooledSpan, paletteIndex: nil)
            }
        }

        private mutating func append(_ node: LensNode, ring: Int, start: Double, span: Double, paletteIndex: Int?) {
            // A single slice that fills the circle would start and end at the same angle and draw nothing.
            let end = min(start + span, start + 0.99999)
            rings[ring - 1].append(
                Sector(
                    id: nextID, ring: ring, start: start, end: end, node: node,
                    paletteIndex: node.kind == .other ? nil : paletteIndex))
            nextID += 1
        }
    }
}

/// Colors for the sunburst and the list bars. One hue per top-level child; deeper rings are lighter.
nonisolated enum SunburstPalette {
    private static let hues: [Color] = [
        .blue, .purple, .pink, .red, .orange, .yellow, .green, .teal, .indigo, .cyan, .mint, .brown,
    ]

    static var count: Int { hues.count }

    /// Color for a slice. `index` is the top-level child's palette index, `ring` is 1...3.
    static func color(index: Int?, ring: Int) -> Color {
        let lightening = [0.0, 0.22, 0.4][min(max(ring, 1), 3) - 1]
        guard let index else { return Color.gray.mix(with: .white, by: lightening * 0.6) }
        return hues[index % hues.count].mix(with: .white, by: lightening)
    }
}
