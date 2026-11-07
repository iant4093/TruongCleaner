import CleanerScanner
import SwiftUI

/// The pages of the welcome sheet, in order.
private enum OnboardingStep: Int, CaseIterable {
    case welcome, safety, access

    var symbol: String {
        switch self {
        case .welcome: "internaldrive.fill"
        case .safety: "checkmark.shield.fill"
        case .access: "lock.shield.fill"
        }
    }

    var color: Color {
        switch self {
        case .welcome: .blue
        case .safety: .green
        case .access: .gray
        }
    }

    var title: String {
        switch self {
        case .welcome: "Welcome to TruongCleaner"
        case .safety: "Your files stay yours"
        case .access: "Full Disk Access"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: "See where your disk space went, and free it safely."
        case .safety: "Nothing is removed without you, and most of it can be undone."
        case .access: "Optional. It lets TruongCleaner measure protected folders."
        }
    }
}

/// The welcome sheet: what the app does, what it never touches, and the optional Full Disk Access step.
///
/// It appears once on first launch and any time from Help > Welcome to TruongCleaner. The pages use plain
/// Back and Continue buttons, with no tab view.
struct OnboardingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step: OnboardingStep = .welcome
    @State private var showFallbackHint = false
    @State private var isChecking = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    PageHeader(
                        symbol: step.symbol,
                        color: step.color,
                        title: step.title,
                        subtitle: step.subtitle
                    )
                }
                switch step {
                case .welcome: welcomeSections
                case .safety: safetySections
                case .access: accessSections
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 520, height: 480)
    }

    // MARK: Pages

    @ViewBuilder
    private var welcomeSections: some View {
        Section {
            Label("Shows what uses your disk, including what macOS calls System Data.", systemImage: "chart.bar.fill")
            Label("Finds caches, logs and build files that apps make again.", systemImage: "sparkles")
            Label("Explains each item in plain words before you choose.", systemImage: "text.alignleft")
        }
    }

    @ViewBuilder
    private var safetySections: some View {
        Section {
            Label(
                "Cleaning moves items to the Trash. History lists every item, and you can put it back.",
                systemImage: "trash"
            )
            Label(
                "Items that are open, or whose app is running, are skipped, and TruongCleaner says why.",
                systemImage: "hand.raised"
            )
            Label(
                "It never touches iCloud files, Photos libraries, your mail or Messages attachments.",
                systemImage: "lock.shield"
            )
            Label(
                "It does nothing in the background and collects no data.",
                systemImage: "moon.zzz"
            )
        }
    }

    @ViewBuilder
    private var accessSections: some View {
        Section("Status") {
            LabeledContent("Full Disk Access") {
                Label(statusTitle, systemImage: statusSymbol)
                    .foregroundStyle(statusColor)
            }
            Text(statusExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Privacy Settings") {
                    showFallbackHint = !SmartCleanActions.openPrivacySettings()
                }
                .accessibilityHint("Opens System Settings so you can turn on Full Disk Access")
                Button("Check Again") {
                    Task {
                        isChecking = true
                        await model.refreshAccess()
                        isChecking = false
                    }
                }
                .disabled(isChecking)
            }
            if showFallbackHint {
                Text("Open System Settings > Privacy & Security > Full Disk Access and turn on TruongCleaner.")
                    .font(.callout)
            }
        }
        Section {
            Text(
                "TruongCleaner works without it. Folders that need it show \"Needs Full Disk Access\", "
                    + "and their size is unknown, not zero. After you turn it on, macOS may ask you to quit "
                    + "and reopen TruongCleaner. After each update macOS may ask again, "
                    + "because the app is signed ad hoc."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Back") { move(by: -1) }
                .disabled(step == .welcome)
            Spacer()
            Text("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            if step == .access {
                Button(model.access == .granted ? "Done" : "Skip for now") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { move(by: 1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func move(by offset: Int) {
        guard let next = OnboardingStep(rawValue: step.rawValue + offset) else { return }
        step = next
    }

    // MARK: Access state

    private var statusTitle: String {
        switch model.access {
        case .granted: "Granted"
        case .notGranted: "Not granted"
        case .unknown: "Unknown"
        }
    }

    private var statusSymbol: String {
        switch model.access {
        case .granted: "checkmark.circle.fill"
        case .notGranted: "lock.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch model.access {
        case .granted: .green
        case .notGranted: .orange
        case .unknown: .secondary
        }
    }

    private var statusExplanation: String {
        switch model.access {
        case .granted:
            "TruongCleaner can open protected folders, so it can measure everything its rules cover."
        case .notGranted:
            "Without it, folders such as Safari's and Mail's caches cannot be measured or cleaned. "
                + "In System Settings, turn on TruongCleaner under Full Disk Access."
        case .unknown:
            "TruongCleaner could not tell. Choose Check Again after changing the setting."
        }
    }
}
