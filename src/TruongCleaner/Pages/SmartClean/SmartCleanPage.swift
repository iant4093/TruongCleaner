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

    private func scanningForm(_ progress: ScanProgress) -> some View {
        Form {
            header("Scanning…")

            Section {
                ForEach(model.categoryProgress) { item in
                    HStack(spacing: 12) {
                        Text(item.category.smartCleanTitle)
                        Spacer(minLength: 8)
                        if item.isDone {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityLabel("Done")
                        } else {
                            ProgressView(value: Double(item.finishedRules), total: Double(item.totalRules))
                                .progressViewStyle(.linear)
                                .frame(width: 90)
                                .accessibilityLabel("\(item.category.smartCleanTitle) progress")
                        }
                        SizeText(bytes: item.bytes)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 70, alignment: .trailing)
                            .opacity(item.finishedRules == 0 ? 0 : 1)
                    }
                    .accessibilityElement(children: .combine)
                }
            } footer: {
                Text("\(progress.files.formatted()) files checked")
                    .monospacedDigit()
            }

            Section {
                HStack {
                    Spacer()
                    Button("Stop") { model.stopScan() }
                        .controlSize(.large)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
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

            ForEach(model.sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        SmartCleanRuleRow(row: row, model: model, access: app.access)
                    }
                } header: {
                    sectionHeader(section)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isCleaning)
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
        HStack {
            if section.selectableRows.isEmpty {
                Text(section.category.smartCleanTitle)
            } else {
                Toggle(
                    section.category.smartCleanTitle,
                    isOn: Binding(
                        get: { model.isSelected(section) },
                        set: { model.setSelected($0, for: section) }
                    )
                )
                .toggleStyle(.checkbox)
                .accessibilityLabel("Select all in \(section.category.smartCleanTitle)")
            }
            Spacer()
            SizeText(bytes: section.bytes)
                .foregroundStyle(.secondary)
        }
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

/// One rule in the results: checkbox, explanation, size, and the items behind it.
struct SmartCleanRuleRow: View {
    let row: SmartCleanRow
    let model: SmartCleanModel
    let access: AccessState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if row.topFindings.isEmpty {
                summary
            } else {
                DisclosureGroup {
                    ForEach(row.topFindings) { finding in
                        ItemRow(finding: finding)
                    }
                    if row.result.findings.count > row.topFindings.count {
                        Text("and \((row.result.findings.count - row.topFindings.count).formatted()) more")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    summary
                }
            }
            if row.needsAccess {
                NeedsAccessRow(kind: accessKind, openPrivacySettings: SmartCleanActions.openPrivacySettings)
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            if row.isSelectable {
                Toggle(
                    isOn: Binding(
                        get: { model.isSelected(row) },
                        set: { model.setSelected($0, for: row) }
                    )
                ) {
                    titleAndExplanation
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel("\(String(localized: row.rule.title)), \(SizeText.spoken(row.bytes))")
                .accessibilityHint(String(localized: row.rule.explain))
            } else {
                // Info rows and rows with nothing to clean never have a checkbox.
                titleAndExplanation
            }
            Spacer(minLength: 8)
            if let label = tierLabel {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SizeText(bytes: row.bytes, isUnknown: row.sizeIsUnknown)
                .foregroundStyle(.secondary)
        }
    }

    private var titleAndExplanation: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.rule.title)
            Text(row.rule.explain)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var tierLabel: String? {
        switch row.rule.tier {
        case .safe: nil
        case .review: "Review"
        case .info: "Information only"
        }
    }

    private var accessKind: NeedsAccessRow.Kind {
        if row.rule.access == .root { return .administratorOnly }
        return access == .granted ? .refusedByMacOS : .fullDiskAccess
    }
}

/// One item under a rule: icon, name, size, Reveal in Finder. Space opens Quick Look.
struct ItemRow: View {
    let finding: Finding
    @State private var quickLookURL: URL?

    var body: some View {
        HStack(spacing: 8) {
            FileIcon(url: finding.url)
            Text(finding.url.lastPathComponent)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(finding.url.path)
            Spacer(minLength: 8)
            SizeText(bytes: finding.allocatedBytes)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                SmartCleanActions.reveal(finding.url)
            } label: {
                Image(systemName: "magnifyingglass.circle")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(finding.url.lastPathComponent) in Finder")
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
