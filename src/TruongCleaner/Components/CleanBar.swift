import SwiftUI

/// Liquid Glass for floating controls. With Reduce Transparency on it becomes an opaque material.
struct FloatingGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
        } else {
            content.glassEffect(.regular, in: .capsule)
        }
    }
}

/// The floating bar at the bottom of Smart Clean: a summary and the Clean button (⌘⌫).
struct CleanBar: View {
    /// "Move about 18.2 GB to the Trash".
    let summary: String
    /// A smaller line under the summary, such as "At least 12.1 GB is yours alone". Optional.
    var detail: String?
    let canClean: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary)
                        .font(.callout.weight(.medium))
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .modifier(FloatingGlass())
                .accessibilityElement(children: .combine)
                cleanButton
            }
        }
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var cleanButton: some View {
        if reduceTransparency {
            Button("Clean", action: action)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!canClean)
        } else {
            Button("Clean", action: action)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!canClean)
        }
    }
}

/// Replaces the clean bar while a clean runs.
struct CleanProgressBar: View {
    let done: Int
    let total: Int

    var body: some View {
        HStack(spacing: 12) {
            if total > 0 {
                ProgressView(value: Double(done), total: Double(total))
                    .frame(width: 140)
                    .accessibilityLabel("Cleaning progress")
                Text("Cleaning \(done.formatted()) of \(total.formatted())")
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Cleaning")
                Text("Cleaning…")
            }
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .modifier(FloatingGlass())
        .padding(.bottom, 14)
    }
}
