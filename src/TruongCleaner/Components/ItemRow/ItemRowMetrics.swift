import SwiftUI

/// Fixed column sizes shared by every `ItemRow`, `FindingRow` and `ItemRowSectionHeader`, so all titles
/// start at one x and all sizes end at one x, whatever a row has or lacks.
///
/// ```text
/// | chevron | gap | checkbox | gap | tile | gap | title ............ | badge | gap | size | gap | action |
/// ```
nonisolated enum ItemRowMetrics {
    /// Width of the disclosure chevron column.
    static let chevronWidth: CGFloat = 12
    /// Width of the checkbox column.
    static let checkboxWidth: CGFloat = 16
    /// Width of the icon tile column.
    static let tileWidth: CGFloat = 24
    /// Space between columns.
    static let gap: CGFloat = 8
    /// Width of the size column. Sizes are right-aligned in it.
    static let sizeWidth: CGFloat = 84
    /// Width reserved for the badge capsule, whether or not a row has one.
    static let badgeWidth: CGFloat = 88
    /// Width of the icon-only action in a `FindingRow` (Reveal in Finder).
    static let iconButtonWidth: CGFloat = 24
    /// Width of the ellipsis menu button.
    static let menuWidth: CGFloat = 24
    /// Space above and below a row's content.
    static let verticalPadding: CGFloat = 3
    /// Distance from the row's leading edge to where titles start.
    static let titleOffset = chevronWidth + gap + checkboxWidth + gap + tileWidth + gap
    /// Distance from the row's leading edge to the checkbox column.
    static let checkboxOffset = chevronWidth + gap
    /// How far a section header's content is pushed in so that its checkbox sits over the rows' checkbox
    /// column. A grouped form indents row content more than it indents section headers.
    static let headerLeadingInset: CGFloat = 0
    /// How far a section header's content is pulled in on the right, so its total sits over the size column.
    static let headerTrailingInset: CGFloat = 0
}

/// Which trailing action column the rows of a page reserve. Every row on the page reserves the same width,
/// so sizes end at the same x whether a row has an action or not.
nonisolated enum ItemRowActionColumn: Sendable {
    /// No action column.
    case none
    /// A single icon button, such as Reveal in Finder.
    case icon
    /// One short button, such as Run….
    case compactButton
    /// One button and an ellipsis menu for the other actions.
    case buttonAndMenu

    /// Width of the whole column.
    var width: CGFloat {
        switch self {
        case .none: 0
        case .icon: ItemRowMetrics.iconButtonWidth
        case .compactButton: buttonWidth
        case .buttonAndMenu: buttonWidth + 4 + ItemRowMetrics.menuWidth
        }
    }

    /// Width every text button in the column has, so buttons in different rows match.
    var buttonWidth: CGFloat {
        switch self {
        case .none, .icon: 96
        case .compactButton: 84
        case .buttonAndMenu: 96
        }
    }
}

extension EnvironmentValues {
    /// The action column the rows below reserve.
    @Entry var itemRowActionColumn = ItemRowActionColumn.none
}

extension View {
    /// Sets the action column that `ItemRow`, `FindingRow` and `ItemRowSectionHeader` below reserve.
    func itemRowActionColumn(_ column: ItemRowActionColumn) -> some View {
        environment(\.itemRowActionColumn, column)
    }
}

extension VerticalAlignment {
    private nonisolated struct TitleCenterID: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }

    /// The vertical middle of a row's title line. Chevron, checkbox, tile, badge, size and action align to it
    /// instead of to the middle of the whole row, which moves when the explanation wraps.
    static let titleCenter = VerticalAlignment(TitleCenterID.self)
}
