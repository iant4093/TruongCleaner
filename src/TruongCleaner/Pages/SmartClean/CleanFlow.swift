import CleanerActions
import CleanerCore
import SwiftUI

/// What a clean is about to do, for the confirmation dialogs: the total and one line per group.
struct CleanConfirmation {
    /// Allocated bytes of everything that will be cleaned. Shown as "about".
    let bytes: Int64
    /// One line per group, such as "Developer: 3.2 GB".
    let lines: [String]
}

/// The steps around a clean that Smart Clean and the Developer page share: the confirmation (with a
/// second one for permanent delete) and the result sheet.
///
/// The page decides when `isPresented` turns on, which items are selected, and what `start` does.
/// The dialogs and the result sheet are the same everywhere.
struct CleanFlow: ViewModifier {
    let model: SmartCleanModel
    let summary: CleanConfirmation
    @Binding var isPresented: Bool
    /// Starts the clean. The Bool is `permanentConfirmed`.
    let start: (DeleteMode, Bool) -> Void

    @State private var showPermanentConfirm = false

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                confirmTitle, isPresented: $isPresented, titleVisibility: .visible
            ) {
                switch model.deleteMode {
                case .trash:
                    Button("Move to Trash") { start(.trash, false) }
                case .permanent:
                    Button("Delete…", role: .destructive) { showPermanentConfirm = true }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirmMessage)
            }
            .confirmationDialog(
                "Delete \(ByteFormatter.string(summary.bytes)) permanently?",
                isPresented: $showPermanentConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete Permanently", role: .destructive) { start(.permanent, true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The space is freed now. Deleted items cannot be put back.")
            }
            .sheet(isPresented: resultBinding) {
                if let report = model.finishedReport {
                    CleanResultSheet(model: model, report: report)
                }
            }
    }

    private var confirmTitle: String {
        let size = ByteFormatter.string(summary.bytes)
        switch model.deleteMode {
        case .trash: return "Move about \(size) to the Trash?"
        case .permanent: return "Delete about \(size)?"
        }
    }

    private var confirmMessage: String {
        let footer = switch model.deleteMode {
        case .trash: "Items go to the Trash. You can put them back."
        case .permanent: "You will be asked to confirm once more. Deleted items cannot be put back."
        }
        return (summary.lines + [footer]).joined(separator: "\n")
    }

    private var resultBinding: Binding<Bool> {
        Binding(
            get: { model.finishedReport != nil },
            set: { if !$0 { model.dismissResult() } }
        )
    }
}

extension View {
    /// Adds the clean confirmation dialogs and the result sheet (see ``CleanFlow``).
    func cleanFlow(
        model: SmartCleanModel,
        summary: CleanConfirmation,
        isPresented: Binding<Bool>,
        start: @escaping (DeleteMode, Bool) -> Void
    ) -> some View {
        modifier(CleanFlow(model: model, summary: summary, isPresented: isPresented, start: start))
    }
}

/// The words on the floating clean bar, shared by Smart Clean and the Developer page.
enum CleanBarText {
    /// "Move about 18.2 GB to the Trash", or "Nothing selected".
    static func summary(bytes: Int64, itemCount: Int, mode: DeleteMode) -> String {
        guard itemCount > 0 else { return "Nothing selected" }
        let size = ByteFormatter.string(bytes)
        switch mode {
        case .trash: return "Move about \(size) to the Trash"
        case .permanent: return "Delete about \(size)"
        }
    }

    /// "12 items · at least 3 GB is used by these items alone", or `nil` when nothing is selected.
    static func detail(itemCount: Int, privateBytes: Int64) -> String? {
        guard itemCount > 0 else { return nil }
        return "\(itemsText(itemCount)) · at least "
            + "\(ByteFormatter.string(privateBytes)) is used by these items alone"
    }
}
