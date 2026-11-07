import SwiftUI

/// Smart Clean "results" state (docs/UI.md §4.2).
struct SmartCleanPage: View {
    @State private var selected = FakeData.defaultSelection

    private var allItems: [CleanItem] { FakeData.cleanGroups.flatMap(\.items) }

    private var selectedGigabytes: Double {
        allItems.filter { selected.contains($0.id) }.map(\.gigabytes).reduce(0, +)
    }

    private var summary: String {
        selected.isEmpty
            ? "Nothing selected"
            : "Move about \(sizeText(selectedGigabytes)) to the Trash"
    }

    var body: some View {
        Form {
            Section {
                PageHeader(
                    symbol: "sparkles",
                    color: .blue,
                    title: "Smart Clean",
                    subtitle: "Scan finished in 4.2 s. Safe items are selected. Review items are not."
                )
            }

            ForEach(FakeData.cleanGroups) { group in
                Section {
                    ForEach(group.items) { item in
                        CleanRow(item: item, isOn: binding(for: item))
                    }
                } header: {
                    HStack {
                        Text(group.title)
                        Spacer()
                        Text(sizeText(group.items.map(\.gigabytes).reduce(0, +)))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            CleanBar(summary: summary, canClean: !selected.isEmpty)
        }
    }

    private func binding(for item: CleanItem) -> Binding<Bool> {
        Binding(
            get: { selected.contains(item.id) },
            set: { isOn in
                if isOn { selected.insert(item.id) } else { selected.remove(item.id) }
            }
        )
    }
}

struct CleanRow: View {
    let item: CleanItem
    @Binding var isOn: Bool

    var body: some View {
        if item.children.isEmpty {
            rowContent
        } else {
            DisclosureGroup {
                ForEach(item.children) { child in
                    HStack {
                        Text(child.name).font(.callout)
                        Spacer()
                        Text(sizeText(child.gigabytes)).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } label: {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            if item.tier == .info {
                // Info rows never delete, so there is no checkbox.
                infoLabel
            } else {
                Toggle(isOn: $isOn) { infoLabel }
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("\(item.title), \(spokenSize(item.gigabytes))")
                    .accessibilityHint(item.explain)
            }
            Spacer(minLength: 8)
            if item.tier != .safe {
                Text(item.tier.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(sizeText(item.gigabytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel(spokenSize(item.gigabytes))
        }
    }

    private var infoLabel: some View {
        HStack(spacing: 10) {
            IconTile(symbol: item.symbol, color: item.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                Text(item.explain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
