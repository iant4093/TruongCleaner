import CleanerActions
import CleanerCore
import Foundation

/// An owner command as the page shows it: the rule behind it and the exact commands it runs, in order.
///
/// Built from the catalog and `OwnerCommands.all`, so the text on screen is the argv that runs. A rule
/// whose command is not on the allow-list gets no value, and the page shows nothing to run for it.
nonisolated struct DeveloperCommand: Identifiable, Sendable {
    /// One command of the chain. Docker's unused-image prune is followed by a build-cache prune.
    struct Step: Sendable {
        let id: OwnerCommandID
        /// Executables the runner tries, in order.
        let candidates: [String]
        let arguments: [String]

        /// The first candidate in `existing`, which is where the runner would launch it, or `nil`.
        func executable(in existing: Set<String>) -> String? {
            candidates.first(where: existing.contains)
        }

        /// The command as text, such as `/opt/homebrew/bin/brew cleanup --prune=30`. Before the tool
        /// is found it shows the first place the runner would look.
        func text(in existing: Set<String>) -> String {
            ([executable(in: existing) ?? candidates.first ?? "?"] + arguments).joined(separator: " ")
        }
    }

    let rule: Rule
    let steps: [Step]

    var id: String { rule.id }

    /// Builds the command for a rule, or `nil` when the rule has no owner command or it is not allowed.
    init?(rule: Rule) {
        guard case .ownerCommand(let spec) = rule.action else { return nil }
        let specs = [spec] + spec.followUps
        let steps = specs.compactMap { spec -> Step? in
            let id = OwnerCommandID(rawValue: spec.id)
            guard let definition = OwnerCommands.all[id] else { return nil }
            return Step(id: id, candidates: definition.candidates, arguments: definition.arguments)
        }
        // A chain with a missing step would run only part of what the rule promises. Run none of it.
        guard steps.count == specs.count else { return nil }
        self.rule = rule
        self.steps = steps
    }

    /// Every executable path the runner may try, for one check of what is installed.
    var candidatePaths: [String] { steps.flatMap(\.candidates) }

    /// Whether every step has an executable on this Mac. `existing` is the set of candidate paths that exist.
    func isInstalled(in existing: Set<String>) -> Bool {
        steps.allSatisfy { $0.executable(in: existing) != nil }
    }

    /// Every step as text, one per line, for the confirmation.
    func commandText(in existing: Set<String>) -> String {
        steps.map { $0.text(in: existing) }.joined(separator: "\n")
    }
}

/// What one run of a command did, for the row and its output disclosure.
nonisolated struct DeveloperCommandRun: Sendable {
    /// One step that ran or was refused.
    struct Step: Sendable {
        let text: String
        let result: OwnerCommandResult
    }

    let steps: [Step]
    let finishedAt: Date

    /// The step that decided the outcome: the first that did not succeed, or the last one.
    private var deciding: Step? {
        steps.first(where: { !$0.result.succeeded }) ?? steps.last
    }

    /// True when every step ran and exited 0.
    var succeeded: Bool { !steps.isEmpty && steps.allSatisfy(\.result.succeeded) }

    /// True when the tool is not on this Mac.
    var toolMissing: Bool { deciding?.result.isToolMissing == true }

    /// One line in plain words.
    var summary: String {
        deciding?.result.summaryText ?? "Nothing ran"
    }

    /// The output of every step that ran, each under its command.
    var output: String {
        steps.compactMap { step -> String? in
            let tail = step.result.outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard step.result.skipped == nil else { return nil }
            return tail.isEmpty ? "$ \(step.text)\n(no output)" : "$ \(step.text)\n\(tail)"
        }.joined(separator: "\n\n")
    }
}
