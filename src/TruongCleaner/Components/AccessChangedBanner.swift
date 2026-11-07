import SwiftUI

/// Tells the user that Full Disk Access was granted after the results on screen were measured
/// (REQ-PERM-03). It offers a new scan and never starts one itself.
struct AccessChangedBanner: View {
    /// Starts the page's scan again.
    let scanAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Full Disk Access changed — Scan again", systemImage: "lock.open.fill")
                Spacer(minLength: 8)
                Button("Scan Again", action: scanAgain)
                    .controlSize(.small)
                    .accessibilityHint("Measures again so protected folders are included")
            }
            Text("These results were measured before the change, so protected folders may be missing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }
}
