import SwiftUI

/// The (i) button that opens a popover explaining a number in plain words.
struct InfoButton: View {
    /// Name of the number, used for the VoiceOver label.
    let subject: String
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
        .accessibilityLabel("About \(subject)")
        .popover(isPresented: $isShown, arrowEdge: .trailing) {
            Text(text)
                .font(.callout)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
        }
    }
}
