import CleanerActions
import CleanerCore
import CleanerScanner
import QuickLook
import SwiftUI

/// Smart Clean (`docs/UI.md` §4.2): scan, review grouped results, clean.
struct SmartCleanPage: View {
    @Bindable var model: SmartCleanModel
    @SwiftUI.Environment(AppModel.self) private var app
    @State private var showConfirm = false

    var body: some View {
        content
            .safeAreaInset(edge: .bottom) { bottomBar }
            .cleanFlow(model: model, summary: confirmation, isPresented: $showConfirm) { mode, confirmed in
                model.clean(mode: mode, permanentConfirmed: confirmed)
            }
    }

    // MARK: Content by state

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            introForm
        case .scanning(let progress):
            scanningForm(progress)
        case .results, .cleaning, .finished:
            resultsForm
        }
    }

    private func header(_ subtitle: String) -> some View {
        Section {
            PageHeader(
                symbol: Page.smartClean.symbol,
                color: Page.smartClean.color,
                title: Page.smartClean.title,
                subtitle: subtitle
            )
        }
    }

    // MARK: Before a scan

    private var introForm: some View {
        Form {
            header("Find what is safe to remove, then move it to the Trash.")

            if let notice = model.notice {
                Section {
                    Label(notice, systemImage: "exclamationmark.triangle")
                }
            }

            Section {
                ForEach(model.categoriesChecked, id: \.self) { category in
                    Label(category.smartCleanTitle, systemImage: "checkmark")
                }
            } header: {
                Text("What is checked")
            } footer: {
                Text("Nothing is removed until you review the results and choose Clean.")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Scan") { model.scan() }
                        .modifier(ProminentActionButton())
                        .controlSize(.large)
                        .accessibilityHint("Looks for caches, logs and other items that are safe to remove")
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: During a scan

    /// Progress at the top, then every section as soon as its rules have finished.
    private func scanningForm(_ progress: ScanProgress) -> some View {
        Form {
            header(scanningSubtitle)

            Section {
                ProgressView(value: Double(model.finishedRuleCount), total: Double(max(1, model.totalRuleCount))) {
                    Text("\(model.finishedRuleCount) of \(model.totalRuleCount) checks done")
                        .monospacedDigit()
                }
                .progressViewStyle(.linear)
                .accessibilityLabel("Scan progress")
                .accessibilityValue("\(model.finishedRuleCount) of \(model.totalRuleCount) checks done")
                HStack {
                    Text("\(progress.files.formatted()) files checked")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { model.stopScan() }
                }
            } footer: {
                if let waiting = stillChecking {
                    Text("Still checking: \(waiting)")
                }
            }

            resultSections
        }
        .formStyle(.grouped)
        .itemRowActionColumn(.icon)
    }

    private var scanningSubtitle: String {
        "Scanning… Results appear below as each check finishes."
    }

    /// Names of the categories that still have checks running, for the footer. `nil` when none.
    private var stillChecking: String? {
        let names = model.categoryProgress.filter { !$0.isDone }.map(\.category.smartCleanTitle)
        return names.isEmpty ? nil : names.formatted(.list(type: .and))
    }

    // MARK: Results

    private var resultsForm: some View {
        Form {
            header(resultsSubtitle)

            if let notice = model.notice {
                Section {
                    Label(notice, systemImage: "exclamationmark.triangle")
                }
            }

            if model.accessChangedSinceScan, case .results = model.state {
                Section { AccessChangedBanner { model.scan() } }
            }

            if model.sections.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Nothing to Clean",
                        systemImage: "checkmark.seal",
                        description: Text("The scan did not find anything these rules would remove.")
                    )
                }
            }

            resultSections
        }
        .formStyle(.grouped)
        .itemRowActionColumn(.icon)
        .disabled(model.isCleaning)
    }

    /// One section per category with something to show. Used while scanning and when the scan is done.
    @ViewBuilder
    private var resultSections: some View {
        ForEach(model.sections) { section in
            Section {
                ForEach(section.rows) { row in
                    SmartCleanRuleRow(row: row, model: model)
                }
                SectionAccessFooter(rows: section.rows, access: app.access)
            } header: {
                sectionHeader(section)
            }
        }
    }

    private var resultsSubtitle: String {
        if model.scanWasPartial {
            return "The scan stopped early. These are the items found so far."
        }
        let seconds = model.scanDuration.map { duration -> String in
            let parts = duration.components
            let value = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            return value.formatted(.number.precision(.fractionLength(1)))
        }
        let time = seconds.map { "Scan finished in \($0) s. " } ?? ""
        return time + "Safe items are selected. Review items are not."
    }

    private func sectionHeader(_ section: SmartCleanSection) -> some View {
        ItemRowSectionHeader(
            title: section.category.smartCleanTitle,
            selection: section.selectableRows.isEmpty
                ? nil
                : Binding(
                    get: { model.isSelected(section) },
                    set: { model.setSelected($0, for: section) }
                ),
            bytes: section.bytes
        )
    }

    // MARK: Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        switch model.state {
        case .results:
            if !model.sections.isEmpty {
                CleanBar(
                    summary: barSummary,
                    detail: barDetail,
                    canClean: model.selectedItemCount > 0
                ) {
                    showConfirm = true
                }
            }
        case .cleaning(let progress):
            CleanProgressBar(done: progress?.done ?? 0, total: progress?.total ?? 0)
        case .idle, .scanning, .finished:
            EmptyView()
        }
    }

    private var barSummary: String {
        CleanBarText.summary(bytes: model.selectedBytes, itemCount: model.selectedItemCount, mode: model.deleteMode)
    }

    private var barDetail: String? {
        CleanBarText.detail(itemCount: model.selectedItemCount, privateBytes: model.selectedPrivateBytes)
    }

    // MARK: Confirmation

    private var confirmation: CleanConfirmation {
        CleanConfirmation(
            bytes: model.selectedBytes,
            lines: model.selectedBytesByCategory.map {
                "\($0.category.smartCleanTitle): \(ByteFormatter.string($0.bytes))"
            }
        )
    }
}

/// One rule in the results, as an `ItemRow`: checkbox, tile, explanation, tier badge, size, and the items
/// behind it under the chevron.
struct SmartCleanRuleRow: View {
    let row: SmartCleanRow
    let model: SmartCleanModel

    var body: some View {
        ruleRow
    }

    private var ruleRow: ItemRow {
        var item = ItemRow(
            icon: .rule(row.rule),
            title: String(localized: row.rule.title),
            explain: String(localized: row.rule.explain),
            size: row.sizeIsUnknown ? .unknown : .bytes(row.bytes)
        )
        .badge(badge)
        if row.isSelectable {
            item = item.selection(
                Binding(
                    get: { model.isSelected(row) },
                    set: { model.setSelected($0, for: row) }
                ))
        }
        if !row.topFindings.isEmpty {
            item = item.disclosure {
                ForEach(row.topFindings) { finding in
                    FindingRow(finding: finding)
                }
                if row.result.findings.count > row.topFindings.count {
                    Text("and \((row.result.findings.count - row.topFindings.count).formatted()) more")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        return item
    }

    private var badge: ItemRowBadge? {
        switch row.rule.tier {
        case .review: .review
        case .info: .info
        case .safe: row.needsAccess ? .needsAccess : nil
        }
    }
}

/// One item under a rule: icon, name, size, Reveal in Finder. Space opens Quick Look.
///
/// Its size ends at the same x as the size of the rule row above it, and the Reveal button sits in the
/// page's action column.
struct FindingRow: View {
    let finding: Finding
    @State private var quickLookURL: URL?

    @SwiftUI.Environment(\.itemRowActionColumn) private var column

    var body: some View {
        HStack(spacing: ItemRowMetrics.gap) {
            FileIcon(url: finding.url)
            Text(finding.url.lastPathComponent)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(finding.url.path)
                .frame(maxWidth: .infinity, alignment: .leading)
            SizeText(bytes: finding.allocatedBytes)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: ItemRowMetrics.sizeWidth, alignment: .trailing)
            if column != .none {
                Button {
                    SmartCleanActions.reveal(finding.url)
                } label: {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(finding.url.lastPathComponent) in Finder")
                .frame(width: column.width, alignment: .trailing)
            }
        }
        .focusable()
        .quickLookPreview($quickLookURL)
        .onKeyPress(.space) {
            quickLookURL = finding.url
            return .handled
        }
        .contextMenu {
            Button("Quick Look") { quickLookURL = finding.url }
            Button("Reveal in Finder") { SmartCleanActions.reveal(finding.url) }
        }
        .accessibilityAction(named: "Quick Look") { quickLookURL = finding.url }
    }
}
