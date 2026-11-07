import SwiftUI

/// The main button of a page body. It uses Liquid Glass, and with Reduce Transparency on it becomes an
/// opaque bordered button (REQ-UI-04). Toolbar buttons do not need it: the system handles those.
struct ProminentActionButton: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.glassProminent)
        }
    }
}
