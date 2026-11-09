import CleanerCore
import SwiftUI

/// The colored tile at the start of a row.
struct ItemRowIcon {
    let symbol: String
    let color: Color

    /// The tile for a category of rules.
    static func category(_ category: CleanerCore.Category) -> ItemRowIcon {
        switch category {
        case .caches: ItemRowIcon(symbol: "archivebox.fill", color: .brown)
        case .logs: ItemRowIcon(symbol: "doc.text.fill", color: .gray)
        case .trash: ItemRowIcon(symbol: "trash.fill", color: .gray)
        case .browsers: ItemRowIcon(symbol: "globe", color: .blue)
        case .apps: ItemRowIcon(symbol: "macwindow", color: .purple)
        case .developer: ItemRowIcon(symbol: "hammer.fill", color: .indigo)
        case .mail: ItemRowIcon(symbol: "envelope.fill", color: .blue)
        case .ios: ItemRowIcon(symbol: "iphone", color: .green)
        case .installers: ItemRowIcon(symbol: "arrow.down.app.fill", color: .cyan)
        case .system: ItemRowIcon(symbol: "gearshape.2.fill", color: .gray)
        }
    }

    /// The tile for a rule: Info rules keep the look they have on the System Data page, others take their
    /// category's tile.
    static func rule(_ rule: Rule) -> ItemRowIcon {
        if rule.tier == .info {
            let look = SystemDataRow.look(ruleID: rule.id)
            return ItemRowIcon(symbol: look.symbol, color: look.color)
        }
        return category(rule.category)
    }
}

/// The small capsule left of the size. One style for every kind.
enum ItemRowBadge {
    /// Not selected by default; look before cleaning.
    case review
    /// Shown for information; the app does not change it.
    case info
    /// Some folders could not be opened.
    case needsAccess

    var text: String {
        switch self {
        case .review: "Review"
        case .info: "Info"
        case .needsAccess: "Needs access"
        }
    }

    var spoken: String {
        switch self {
        case .review: "Review before cleaning"
        case .info: "Information only. TruongCleaner does not remove this."
        case .needsAccess: "Needs access"
        }
    }
}

/// What the size column shows. The text always fits the column.
enum ItemRowSize {
    case bytes(Int64)
    /// Part of the folder could not be read, so the true size is at least this.
    case atLeast(Int64)
    /// The size could not be measured. Never shown as zero.
    case unknown
    /// A few plain words instead of a number, such as "None".
    case text(String)

    /// The size spelled out for VoiceOver.
    var spoken: String {
        switch self {
        case .bytes(let bytes): SizeText.spoken(bytes)
        case .atLeast(let bytes): "At least \(SizeText.spoken(bytes))"
        case .unknown: "Size unknown"
        case .text(let text): text
        }
    }
}

/// The capsule drawn for an `ItemRowBadge`.
struct ItemRowBadgeView: View {
    let badge: ItemRowBadge

    var body: some View {
        HStack(spacing: 3) {
            if badge == .needsAccess {
                Image(systemName: "lock.fill")
            }
            Text(badge.text)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(.quaternary, in: Capsule())
        .fixedSize()
        .accessibilityLabel(badge.spoken)
    }
}

/// The fixed-width slot that holds a row's badge, right-aligned against the size column.
struct ItemRowBadgeSlot: View {
    let badge: ItemRowBadge?

    var body: some View {
        Group {
            if let badge {
                ItemRowBadgeView(badge: badge)
            } else {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: ItemRowMetrics.badgeWidth, alignment: .trailing)
    }
}

/// The size column: one fixed width, right-aligned, digits that do not jump.
struct ItemRowSizeView: View {
    let size: ItemRowSize

    var body: some View {
        content
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: ItemRowMetrics.sizeWidth, alignment: .trailing)
            .accessibilityLabel(size.spoken)
    }

    @ViewBuilder
    private var content: some View {
        switch size {
        case .bytes(let bytes):
            SizeText(bytes: bytes)
        case .atLeast(let bytes):
            Text("≥ \(ByteFormatter.string(bytes))")
                .monospacedDigit()
                .help("At least this much. Some folders could not be read.")
        case .unknown:
            SizeText(bytes: 0, isUnknown: true)
        case .text(let text):
            Text(text)
        }
    }
}

/// One action of a row. The first action of a row is its button; the others go in the ellipsis menu.
struct ItemRowAction: Identifiable {
    let title: String
    var isDisabled = false
    /// Tooltip, for example why the action is off.
    var help: String?
    var accessibilityLabel: String?
    var accessibilityHint: String?
    let perform: () -> Void

    var id: String { title }
}

/// The trailing actions of a row: at most one visible button, and the rest in an ellipsis menu. All buttons
/// are small, bordered and equally wide.
struct ItemRowActions: View {
    let actions: [ItemRowAction]
    @SwiftUI.Environment(\.itemRowActionColumn) private var column

    var body: some View {
        HStack(spacing: 4) {
            if let primary = actions.first {
                Button {
                    primary.perform()
                } label: {
                    Text(primary.title)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(width: column.buttonWidth)
                .disabled(primary.isDisabled)
                .help(primary.help ?? "")
                .accessibilityLabel(primary.accessibilityLabel ?? primary.title)
                .accessibilityHint(primary.accessibilityHint ?? "")
            }
            if actions.count > 1 {
                Menu {
                    ForEach(actions.dropFirst()) { action in
                        Button(action.title) { action.perform() }
                            .disabled(action.isDisabled)
                            .accessibilityLabel(action.accessibilityLabel ?? action.title)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .menuIndicator(.hidden)
                .controlSize(.small)
                .frame(width: ItemRowMetrics.menuWidth)
                .accessibilityLabel("More actions")
            } else if column == .buttonAndMenu {
                Color.clear.frame(width: ItemRowMetrics.menuWidth, height: 1)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The disclosure chevron: the system look (`chevron.right`, turns down when open), placed in the chevron
/// column. The turn is skipped when Reduce Motion is on.
struct ItemRowChevron: View {
    @Binding var isExpanded: Bool
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: ItemRowMetrics.chevronWidth)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide items" : "Show items")
    }
}

/// Lays an expandable row out so the chevron has its own column, centered on the title line, and the
/// expanded content starts under the titles.
struct ItemRowDisclosureStyle: DisclosureGroupStyle {
    /// The leading columns of the section. The chevron column is always counted, because this style draws it.
    var columns = ItemRowLeadingColumns.all

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .titleCenter, spacing: ItemRowMetrics.gap) {
                ItemRowChevron(isExpanded: configuration.$isExpanded)
                configuration.label
            }
            if configuration.isExpanded {
                configuration.content
                    .padding(.leading, ItemRowMetrics.titleOffset(for: columns.union(.chevron)))
            }
        }
    }
}

/// A section header laid out like the rows below it: the select-all checkbox over the rows' checkbox
/// column and the total over the size column.
struct ItemRowSectionHeader: View {
    let title: String
    /// Select-all for the section, or `nil` when no row has a checkbox.
    var selection: Binding<Bool>?
    /// Total bytes of the section.
    var bytes: Int64?
    @SwiftUI.Environment(\.itemRowActionColumn) private var column
    @SwiftUI.Environment(\.itemRowLeadingColumns) private var leading

    var body: some View {
        HStack(spacing: ItemRowMetrics.gap) {
            if leading.contains(.chevron) {
                Color.clear.frame(width: ItemRowMetrics.chevronWidth, height: 1)
            }
            if let selection {
                Toggle(isOn: selection) { EmptyView() }
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .frame(width: ItemRowMetrics.checkboxWidth)
                    .accessibilityLabel("Select all in \(title)")
            } else if leading.contains(.checkbox) {
                Color.clear.frame(width: ItemRowMetrics.checkboxWidth, height: 1)
            }
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let bytes {
                SizeText(bytes: bytes)
                    .lineLimit(1)
                    .frame(width: ItemRowMetrics.sizeWidth, alignment: .trailing)
            }
            if column != .none {
                Color.clear.frame(width: column.width, height: 1)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, ItemRowMetrics.headerLeadingInset)
        .padding(.trailing, ItemRowMetrics.headerTrailingInset)
    }
}
