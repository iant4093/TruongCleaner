import CleanerActions
import CleanerCore
import Foundation
import Observation

/// What the Put Back button can do for one history item.
nonisolated enum PutBackState: Sendable, Equatable {
    /// Moved to the Trash and not put back or deleted since. The button is on.
    case available
    /// Put back at its original place.
    case putBack
    /// Deleted for good from the Trash by Free Space Now.
    case freed
    /// The item was not moved to the Trash, so there is nothing to put back.
    case notApplicable
}

/// One line in the items table of a clean. Plain values only; built off the main actor.
nonisolated struct HistoryItemRow: Identifiable, Sendable {
    let report: ItemReport
    let putBackState: PutBackState

    var id: UUID { report.findingID }

    var name: String { report.originalPath.lastPathComponent }

    /// The folder the item came from, with the home folder shown as `~`.
    var location: String {
        (report.originalPath.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    /// Allocated bytes on disk at scan time.
    var bytes: Int64 { report.estimatedBytes }

    /// What happened, in plain words. Skipped items say why.
    var outcome: String {
        switch report.outcome {
        case .moved:
            switch putBackState {
            case .putBack: "Moved to the Trash, then put back"
            case .freed: "Moved to the Trash, then deleted from it"
            case .available, .notApplicable: "Moved to the Trash"
            }
        case .deleted: "Deleted"
        case .skipped(let reason): "Skipped: \(reason.userMessage)"
        case .failed(let message): "Failed: \(message)"
        }
    }

    /// Why the Put Back button is off, or nil when it is on or does not apply.
    var putBackDisabledReason: String? {
        switch putBackState {
        case .available, .notApplicable: nil
        case .putBack: "Already put back"
        case .freed: "Already deleted from the Trash"
        }
    }
}

/// One line of the History list: a clean or an owner-command run.
nonisolated enum HistoryEntry: Identifiable, Sendable {
    case clean(CleanSummary)
    case command(CommandRecord)

    var id: UUID {
        switch self {
        case .clean(let clean): clean.id
        case .command(let record): record.id
        }
    }

    var date: Date {
        switch self {
        case .clean(let clean): clean.startedAt
        case .command(let record): record.startedAt
        }
    }
}

extension CommandRecord {
    /// The command's short name, as History shows it.
    var title: String { result.id.title }

    /// How the run ended, in one plain line.
    var statusText: String { result.summaryText }

    /// True when the run finished with exit code 0.
    var succeeded: Bool { result.succeeded }

    /// The tail of the output, trimmed. Empty when there was none or the command did not run.
    var output: String {
        result.skipped == nil ? result.outputTail.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
}

/// Display text for a clean, kept out of the view so it can be read by VoiceOver as one sentence.
extension CleanSummary {
    /// "3 moved · 1 skipped", or "Nothing changed".
    var countsText: String {
        let parts = [
            movedCount > 0 ? "\(movedCount) moved" : nil,
            deletedCount > 0 ? "\(deletedCount) deleted" : nil,
            skippedCount > 0 ? "\(skippedCount) skipped" : nil,
            failedCount > 0 ? "\(failedCount) failed" : nil,
        ].compactMap { $0 }
        let text = parts.isEmpty ? "Nothing changed" : parts.joined(separator: " · ")
        return isFinished ? text : "\(text) · did not finish"
    }

    /// "Moved to the Trash" or "Deleted for good".
    var modeText: String {
        switch mode {
        case .trash: "Trash"
        case .permanent: "Permanent"
        }
    }

    /// The estimate, for example "About 1.2 GB".
    var estimateText: String {
        "About \(ByteFormatter.string(estimatedFreedBytes))"
    }

    /// The measured change in available space, or nil when it was not read.
    var measuredText: String? {
        guard let availableBefore, let availableAfter else { return nil }
        let change = availableAfter - availableBefore
        let sign = change < 0 ? "−" : "+"
        return "\(sign)\(ByteFormatter.string(abs(change)))"
    }
}

/// Reads and writes history off the main actor.
nonisolated enum HistoryWork {
    /// Every clean, newest first.
    @concurrent
    static func loadCleans(from history: HistoryStore) async throws -> [CleanSummary] {
        try await history.cleans()
    }

    /// Every owner-command run, newest first.
    @concurrent
    static func loadCommands(from history: HistoryStore) async throws -> [CommandRecord] {
        try await history.commands()
    }

    /// The items of one clean, each with what happened to it afterwards.
    @concurrent
    static func loadItems(of cleanID: UUID, from history: HistoryStore) async throws -> [HistoryItemRow] {
        let items = try await history.items(of: cleanID)
        let followUps = try await history.followUps().filter { $0.cleanID == cleanID }
        var closed: [UUID: HistoryFollowUp.Kind] = [:]
        for followUp in followUps { closed[followUp.findingID] = followUp.kind }
        return items.map { report in
            guard case .moved = report.outcome else { return HistoryItemRow(report: report, putBackState: .notApplicable) }
            switch closed[report.findingID] {
            case .undone: return HistoryItemRow(report: report, putBackState: .putBack)
            case .freed: return HistoryItemRow(report: report, putBackState: .freed)
            case nil: return HistoryItemRow(report: report, putBackState: .available)
            }
        }
    }

    /// Puts items back one after another. `UndoService` checks the Trash, the file ID and the old
    /// location for each item and writes the history line.
    @concurrent
    static func putBack(
        _ items: [ItemReport], cleanID: UUID, home: URL, history: HistoryStore
    ) async -> [(id: UUID, result: PutBackResult)] {
        let service = UndoService(trash: Services.trashLocations(home: home))
        var results: [(id: UUID, result: PutBackResult)] = []
        for item in items {
            results.append((item.findingID, await service.putBack(item, cleanID: cleanID, history: history)))
        }
        return results
    }
}

/// A line of feedback under the items table.
struct HistoryMessage: Equatable {
    let text: String
    let isError: Bool
}

/// The History page: the cleans on top, the items of the selected clean below.
@Observable @MainActor
final class HistoryModel {
    /// Every clean, newest first.
    private(set) var cleans: [CleanSummary] = []
    /// Every owner-command run, newest first.
    private(set) var commands: [CommandRecord] = []
    /// The clean whose items are shown.
    var selection: UUID?
    /// Items of the selected clean.
    private(set) var rows: [HistoryItemRow] = []
    /// Why a Put Back was refused, by item. Shown in the Outcome column; the button stays off.
    private(set) var refusals: [UUID: String] = [:]
    /// True while the history file is being read for the first time.
    private(set) var isLoading = true
    /// True while items are being put back.
    private(set) var isPuttingBack = false
    /// Feedback for the last read or Put Back.
    private(set) var message: HistoryMessage?

    @ObservationIgnored private let services: Services

    init(services: Services) {
        self.services = services
    }

    /// Cleans and command runs together, newest first.
    var entries: [HistoryEntry] {
        (cleans.map(HistoryEntry.clean) + commands.map(HistoryEntry.command)).sorted { $0.date > $1.date }
    }

    /// Nothing has been recorded: no clean and no command run.
    var isEmpty: Bool { cleans.isEmpty && commands.isEmpty }

    /// The selected clean, if it is still in the list.
    var selectedClean: CleanSummary? {
        cleans.first { $0.id == selection }
    }

    /// Items of the selected clean that Put Back can try.
    var puttableRows: [HistoryItemRow] {
        rows.filter { $0.putBackState == .available && refusals[$0.id] == nil }
    }

    /// Why this item's button is off, or nil when it is on.
    func disabledReason(for row: HistoryItemRow) -> String? {
        if let reason = row.putBackDisabledReason { return reason }
        if let refusal = refusals[row.id] { return refusal }
        if isPuttingBack { return "Another Put Back is running" }
        return nil
    }

    /// The Outcome column: what happened, plus why a Put Back was refused.
    func outcomeText(for row: HistoryItemRow) -> String {
        guard let refusal = refusals[row.id] else { return row.outcome }
        return "\(row.outcome). Cannot put back: \(refusal)"
    }

    /// Called when the page appears. Old refusals are dropped, because the Trash may have changed.
    func appeared() async {
        refusals = [:]
        message = nil
        await reload()
    }

    /// Reads history again and selects the newest clean when nothing valid is selected.
    func reload() async {
        defer { isLoading = false }
        do {
            let loaded = try await HistoryWork.loadCleans(from: services.history)
            let loadedCommands = try await HistoryWork.loadCommands(from: services.history)
            guard !Task.isCancelled else { return }
            cleans = loaded
            commands = loadedCommands
            if selection == nil || selectedClean == nil { selection = loaded.first?.id }
        } catch {
            guard !Task.isCancelled else { return }
            message = HistoryMessage(text: "The history file could not be read.", isError: true)
            return
        }
        await loadItems()
    }

    /// Reads the items of the selected clean.
    func loadItems() async {
        guard let id = selection else {
            rows = []
            return
        }
        do {
            let loaded = try await HistoryWork.loadItems(of: id, from: services.history)
            guard !Task.isCancelled, id == selection else { return }
            rows = loaded
        } catch {
            guard !Task.isCancelled else { return }
            rows = []
            message = HistoryMessage(text: "The items of this clean could not be read.", isError: true)
        }
    }

    /// Puts one item back.
    func putBack(_ row: HistoryItemRow) async {
        await putBack([row])
    }

    /// Puts every available item of the selected clean back.
    func putBackAll() async {
        await putBack(puttableRows)
    }

    private func putBack(_ targets: [HistoryItemRow]) async {
        guard !isPuttingBack, let cleanID = selection, !targets.isEmpty else { return }
        isPuttingBack = true
        defer { isPuttingBack = false }
        message = nil

        let home = FileManager.default.homeDirectoryForCurrentUser
        let results = await HistoryWork.putBack(
            targets.map(\.report), cleanID: cleanID, home: home, history: services.history)

        var restored = 0
        var refused = 0
        for (id, result) in results {
            switch result {
            case .restored:
                restored += 1
                refusals[id] = nil
            case .refused(let refusal):
                refused += 1
                refusals[id] = refusal.userMessage
            case .failed(let detail):
                refused += 1
                refusals[id] = "The move failed (\(detail))"
            }
        }
        message = Self.summary(restored: restored, notRestored: refused)
        await loadItems()
    }

    private static func summary(restored: Int, notRestored: Int) -> HistoryMessage {
        let failed = "\(notRestored) \(notRestored == 1 ? "item" : "items") could not be put back. See the Outcome column."
        switch (restored, notRestored) {
        case (0, 0): return HistoryMessage(text: "Nothing to put back.", isError: false)
        case (_, 0):
            return HistoryMessage(text: "Put back \(restored) \(restored == 1 ? "item" : "items").", isError: false)
        case (0, _): return HistoryMessage(text: failed, isError: true)
        default: return HistoryMessage(text: "Put back \(restored). \(failed)", isError: true)
        }
    }
}
