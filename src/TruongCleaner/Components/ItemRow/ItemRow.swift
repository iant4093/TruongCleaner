import SwiftUI

/// The one row used by Smart Clean, Developer and System Data (and free for other pages):
///
/// ```text
/// [▸] [☐] [tile]  Title                         [badge]  Size   [action ⋯]
///                 Explain text (secondary, two lines at most)
/// ```
///
/// Every column has a fixed width (`ItemRowMetrics`), so titles start at one x and sizes end at one x in
/// every row of a section, whether or not a row has a chevron, checkbox, tile, badge or action. Chevron, checkbox, tile,
/// badge, size and action are centered on the title line, not on the whole row.
///
/// Build a row with the initializer, then add the optional parts with the modifiers:
///
/// ```swift
/// ItemRow(icon: .category(.caches), title: "Caches", explain: "Apps rebuild these.", size: .bytes(bytes))
///     .selection($isOn)                      // a checkbox
///     .badge(.review)                        // a capsule left of the size
///     .actions([ItemRowAction(title: "Open Settings") { … }])
///     .footer { Text("Moved on the next restart") }       // under the explanation, in the title column
///     .disclosure { FindingRow(finding: f) }              // the chevron and what it opens
/// ```
///
/// Set `.itemRowActionColumn(_:)` on the form so that every row reserves the same action width. A section
/// whose rows have no chevron, checkbox or tile sets `.itemRowLeadingColumns(_:)` so that those columns are
/// not reserved there.
struct ItemRow: View {
    var icon: ItemRowIcon?
    var title: String
    var explain: String?
    /// A second sentence for the info popover and tooltip, such as why a number is rough.
    var note: String?
    var size: ItemRowSize?

    private var selectionBinding: Binding<Bool>?
    private var badgeKind: ItemRowBadge?
    private var actionList: [ItemRowAction] = []
    private var trailingView: AnyView?
    private var footerView: AnyView?
    private var disclosureView: AnyView?

    @State private var isExpanded = false
    @State private var showsInfo = false
    @SwiftUI.Environment(\.itemRowActionColumn) private var column
    @SwiftUI.Environment(\.itemRowLeadingColumns) private var leading

    /// Creates a row.
    /// - Parameters:
    ///   - icon: the tile, or `nil` to leave its column empty.
    ///   - title: the name on the first line.
    ///   - explain: the sentence under the title. Two lines show; the tooltip and popover hold all of it.
    ///   - note: more text for the tooltip and popover.
    ///   - size: what the size column shows, or `nil` to leave it empty.
    init(icon: ItemRowIcon? = nil, title: String, explain: String? = nil, note: String? = nil, size: ItemRowSize? = nil) {
        self.icon = icon
        self.title = title
        self.explain = explain
        self.note = note
        self.size = size
    }

    // MARK: Optional parts

    /// Adds a checkbox. VoiceOver reads the title and the size.
    func selection(_ isOn: Binding<Bool>) -> ItemRow {
        var row = self
        row.selectionBinding = isOn
        return row
    }

    /// Adds a capsule left of the size.
    func badge(_ badge: ItemRowBadge?) -> ItemRow {
        var row = self
        row.badgeKind = badge
        return row
    }

    /// Adds actions: the first is the visible button, the rest go in an ellipsis menu.
    func actions(_ actions: [ItemRowAction]) -> ItemRow {
        var row = self
        row.actionList = actions
        return row
    }

    /// Replaces the action column with any view, such as a progress indicator. It is right-aligned in the
    /// column the page reserved.
    func trailing<Content: View>(@ViewBuilder _ content: () -> Content) -> ItemRow {
        var row = self
        row.trailingView = AnyView(content())
        return row
    }

    /// Adds content under the explanation, in the title column.
    func footer<Content: View>(@ViewBuilder _ content: () -> Content) -> ItemRow {
        var row = self
        row.footerView = AnyView(content())
        return row
    }

    /// Adds a chevron. The content shows under the row, starting at the titles, when the chevron is open.
    func disclosure<Content: View>(@ViewBuilder _ content: () -> Content) -> ItemRow {
        var row = self
        row.disclosureView = AnyView(content())
        return row
    }

    // MARK: Body

    var body: some View {
        let titleOffset = ItemRowMetrics.titleOffset(for: leading)
        return rowContent
            .padding(.vertical, ItemRowMetrics.verticalPadding)
            .accessibilityElement(children: .contain)
            // System Settings draws its dividers from the title, not from the row's edge.
            // Lists honor this; a grouped Form on macOS draws its dividers from the row edge regardless.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + titleOffset }
    }

    @ViewBuilder
    private var rowContent: some View {
        if let disclosureView {
            DisclosureGroup(isExpanded: $isExpanded) {
                disclosureView
            } label: {
                line
            }
            .disclosureGroupStyle(ItemRowDisclosureStyle(columns: leading))
        } else {
            HStack(alignment: .titleCenter, spacing: ItemRowMetrics.gap) {
                // Reserved so the titles of rows without a chevron line up with the others.
                if leading.contains(.chevron) {
                    Color.clear.frame(width: ItemRowMetrics.chevronWidth, height: 1)
                        .accessibilityHidden(true)
                }
                line
            }
        }
    }

    /// Everything right of the chevron column.
    private var line: some View {
        HStack(alignment: .titleCenter, spacing: ItemRowMetrics.gap) {
            checkbox
            tile
            textColumn
            // The badge slot is always reserved, so the title column has one width in every row.
            ItemRowBadgeSlot(badge: badgeKind)
            if let size {
                ItemRowSizeView(size: size)
            }
            if column != .none {
                actionSlot
            }
        }
    }

    @ViewBuilder
    private var checkbox: some View {
        if let selectionBinding {
            Toggle(isOn: selectionBinding) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: ItemRowMetrics.checkboxWidth)
                .accessibilityLabel(selectionLabel)
                .accessibilityHint(explain ?? "")
        } else if leading.contains(.checkbox) {
            Color.clear.frame(width: ItemRowMetrics.checkboxWidth, height: 1)
                .accessibilityHidden(true)
        }
    }

    private var selectionLabel: String {
        guard let size else { return title }
        return "\(title), \(size.spoken)"
    }

    @ViewBuilder
    private var tile: some View {
        if let icon {
            IconTile(symbol: icon.symbol, color: icon.color)
        } else if leading.contains(.tile) {
            Color.clear.frame(width: ItemRowMetrics.tileWidth, height: 1)
                .accessibilityHidden(true)
        }
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Like System Settings, the tile, checkbox, chevron, badge, size and button are
            // centered on the title + explanation block, not on the title line alone.
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let explain {
                    Text(note.map { "\(explain) \($0)" } ?? explain)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(fullText)
                        .onTapGesture { showsInfo = true }
                        .accessibilityAction(named: "Show details") { showsInfo = true }
                        .popover(isPresented: $showsInfo, arrowEdge: .bottom) { infoPopover }
                }
            }
            .alignmentGuide(.titleCenter) { $0[VerticalAlignment.center] }
            if let footerView {
                footerView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actionSlot: some View {
        Group {
            if let trailingView {
                trailingView
            } else if !actionList.isEmpty {
                ItemRowActions(actions: actionList)
            } else {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: column.width, alignment: .trailing)
    }

    // MARK: Info popover

    private var fullText: String {
        [explain, note].compactMap { $0 }.joined(separator: "\n\n")
    }

    private var infoPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(fullText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 300, alignment: .leading)
        .padding(14)
    }
}
