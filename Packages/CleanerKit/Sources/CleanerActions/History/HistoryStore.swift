import Foundation

/// Failures of `HistoryStore`. Never contains a path.
public enum HistoryError: Error, Sendable, Equatable {
    /// The history folder or file could not be created or opened.
    case cannotOpen(String)
    /// Writing a line failed.
    case cannotWrite(String)
    /// Reading the file failed.
    case cannotRead(String)
    /// A line could not be encoded.
    case cannotEncode
}

/// The record of every clean: a JSON Lines file, one object per line.
///
/// Line types: `begin` (the plan, written before the first item), `item` (one per item, written
/// as soon as its outcome is known), `finish`, `undone` and `freed`, plus `freeBegin` (the Trash
/// locations Free Space Now is about to delete, written before the first delete) and `command` (one owner-command
/// run, written after it ends). Files from older versions have no `command` lines and read the same.
/// Every line is flushed to disk
/// before the call returns, so a crash leaves a readable file. A truncated last line is skipped
/// on read and never glued to the next line.
public actor HistoryStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Creates a store.
    ///
    /// - Parameter fileURL: The app passes `~/Library/Application Support/TruongCleaner/history.jsonl`.
    ///   Tests pass a file inside a fixture. The folder is created (mode 0700) on the first write.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: Writing

    /// Writes the `begin` line: the mode and every planned item. Call before touching anything.
    public func begin(_ plan: CleanPlan, id: UUID, startedAt: Date = Date()) throws {
        let planned = plan.items.map { entry in
            PlannedRecord(
                findingID: entry.finding.id,
                ruleID: entry.finding.ruleID,
                originalPath: entry.finding.url,
                fsid: entry.finding.fsid,
                fileID: entry.finding.fileID,
                estimatedBytes: entry.finding.allocatedBytes,
                privateBytes: entry.finding.privateBytes)
        }
        try append(
            HistoryLine(
                type: HistoryLine.Kind.begin, cleanID: id, at: startedAt, mode: plan.mode,
                permanentConfirmed: plan.permanentConfirmed, planned: planned))
    }

    /// Writes one `item` line.
    public func record(_ item: ItemReport, cleanID: UUID) throws {
        try append(HistoryLine(type: HistoryLine.Kind.item, cleanID: cleanID, at: Date(), item: item))
    }

    /// Writes the `finish` line.
    public func finish(_ report: CleanReport) throws {
        try append(
            HistoryLine(
                type: HistoryLine.Kind.finish, cleanID: report.id, at: report.finishedAt, mode: report.mode,
                startedAt: report.startedAt, availableBefore: report.availableBefore,
                availableAfter: report.availableAfter))
    }

    /// Writes an `undone` line: the item was put back at `restoredTo`.
    public func recordUndone(findingID: UUID, cleanID: UUID, restoredTo: URL) throws {
        try append(
            HistoryLine(
                type: HistoryLine.Kind.undone, cleanID: cleanID, at: Date(), findingID: findingID, path: restoredTo))
    }

    /// Writes a `freed` line: the item was deleted for good from `trashURL`.
    public func recordFreed(findingID: UUID, cleanID: UUID, trashURL: URL) throws {
        try append(
            HistoryLine(
                type: HistoryLine.Kind.freed, cleanID: cleanID, at: Date(), findingID: findingID, path: trashURL))
    }

    /// Writes a `freeBegin` line: Free Space Now is about to delete these Trash items for good.
    /// Call before the first delete.
    public func recordFreeBegin(trashURLs: [URL], id: UUID = UUID()) throws {
        try append(HistoryLine(type: HistoryLine.Kind.freeBegin, cleanID: id, at: Date(), trashPaths: trashURLs))
    }

    /// Writes a `command` line: one owner-command run and what it did.
    ///
    /// - Parameters:
    ///   - result: What the runner returned, including a skipped command.
    ///   - ruleID: The catalog rule whose action ran.
    ///   - startedAt: When the run began. Defaults to the time the run took, counted back from now.
    public func recordCommand(_ result: OwnerCommandResult, ruleID: String, startedAt: Date? = nil) throws {
        let components = result.duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let began = startedAt ?? Date().addingTimeInterval(-seconds)
        let record = CommandRecord(startedAt: began, ruleID: ruleID, result: result)
        try append(HistoryLine(type: HistoryLine.Kind.command, cleanID: record.id, at: began, command: record))
    }

    // MARK: Reading

    /// Every owner-command run in the file, newest first. A file without such lines gives an empty list.
    /// Dates are stored in whole seconds, so runs that began in the same second keep their file order,
    /// the later line first.
    public func commands() throws -> [CommandRecord] {
        try readLines()
            .compactMap { $0.type == HistoryLine.Kind.command ? $0.command : nil }
            .enumerated()
            .sorted { ($0.element.startedAt, $0.offset) > ($1.element.startedAt, $1.offset) }
            .map(\.element)
    }

    /// Every clean in the file, newest first. A clean without a `finish` line has `isFinished == false`.
    public func cleans() throws -> [CleanSummary] {
        let lines = try readLines()
        var order: [UUID] = []
        var builders: [UUID: SummaryBuilder] = [:]
        for line in lines {
            switch line.type {
            case HistoryLine.Kind.begin:
                if builders[line.cleanID] == nil { order.append(line.cleanID) }
                builders[line.cleanID, default: SummaryBuilder(id: line.cleanID)].apply(begin: line)
            case HistoryLine.Kind.item:
                if let item = line.item { builders[line.cleanID]?.apply(item: item) }
            case HistoryLine.Kind.finish:
                builders[line.cleanID]?.apply(finish: line)
            default:
                continue
            }
        }
        return order.compactMap { builders[$0]?.summary }.sorted { $0.startedAt > $1.startedAt }
    }

    /// The Trash locations of every `freeBegin` line, in the order they were written.
    public func freeBeginPaths() throws -> [[URL]] {
        try readLines().compactMap { $0.type == HistoryLine.Kind.freeBegin ? $0.trashPaths : nil }
    }

    /// The `item` lines of one clean, in the order they were written.
    public func items(of cleanID: UUID) throws -> [ItemReport] {
        try readLines().compactMap { $0.type == HistoryLine.Kind.item && $0.cleanID == cleanID ? $0.item : nil }
    }

    /// Every `undone` and `freed` line, in the order they were written.
    public func followUps() throws -> [HistoryFollowUp] {
        try readLines().compactMap { line in
            guard let findingID = line.findingID, let path = line.path else { return nil }
            switch line.type {
            case HistoryLine.Kind.undone:
                return HistoryFollowUp(
                    kind: .undone, cleanID: line.cleanID, findingID: findingID, at: line.at, path: path)
            case HistoryLine.Kind.freed:
                return HistoryFollowUp(
                    kind: .freed, cleanID: line.cleanID, findingID: findingID, at: line.at, path: path)
            default:
                return nil
            }
        }
    }

    /// Items some clean moved to the Trash that were not put back or freed since, oldest clean first.
    public func trashedItems() throws -> [TrashedItem] {
        let lines = try readLines()
        var closed = Set<String>()
        for line in lines where line.type == HistoryLine.Kind.undone || line.type == HistoryLine.Kind.freed {
            if let findingID = line.findingID { closed.insert("\(line.cleanID)/\(findingID)") }
        }
        return lines.compactMap { line in
            guard line.type == HistoryLine.Kind.item, let item = line.item,
                case .moved(let trashURL) = item.outcome,
                !closed.contains("\(line.cleanID)/\(item.findingID)")
            else { return nil }
            return TrashedItem(cleanID: line.cleanID, item: item, trashURL: trashURL)
        }
    }

    // MARK: File access

    /// Reads the file and decodes each line. A line that does not decode (a truncated last line, or
    /// a line from a newer version) is skipped. A missing file is an empty history.
    private func readLines() throws -> [HistoryLine] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        } catch {
            throw HistoryError.cannotRead(Self.describe(error))
        }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap {
            try? decoder.decode(HistoryLine.self, from: Data($0))
        }
    }

    /// Appends one line and flushes it to disk.
    private func append(_ line: HistoryLine) throws {
        var data: Data
        do { data = try encoder.encode(line) } catch { throw HistoryError.cannotEncode }
        data.append(0x0A)

        let fileManager = FileManager.default
        let folder = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) {
                guard fileManager.createFile(
                    atPath: fileURL.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600])
                else { throw HistoryError.cannotOpen("create") }
            }
        } catch let error as HistoryError {
            throw error
        } catch {
            throw HistoryError.cannotOpen(Self.describe(error))
        }

        let handle: FileHandle
        do { handle = try FileHandle(forUpdating: fileURL) } catch { throw HistoryError.cannotOpen(Self.describe(error)) }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            if end > 0 {
                // A crash can leave a last line without its newline. Never glue a new line to it.
                try handle.seek(toOffset: end - 1)
                let last = try handle.read(upToCount: 1)
                if last != Data([0x0A]) {
                    try handle.seekToEnd()
                    data.insert(0x0A, at: 0)
                }
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            throw HistoryError.cannotWrite(Self.describe(error))
        }
    }

    /// An error in words, without file names.
    private static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }
}

/// Collects the lines of one clean into a `CleanSummary`.
private struct SummaryBuilder {
    let id: UUID
    var startedAt = Date.distantPast
    var finishedAt: Date?
    var mode = DeleteMode.trash
    var planned = 0
    var moved = 0
    var deleted = 0
    var skipped = 0
    var failed = 0
    var estimated: Int64 = 0
    var before: Int64?
    var after: Int64?

    init(id: UUID) { self.id = id }

    mutating func apply(begin line: HistoryLine) {
        startedAt = line.at
        mode = line.mode ?? .trash
        planned = line.planned?.count ?? 0
    }

    mutating func apply(item: ItemReport) {
        switch item.outcome {
        case .moved:
            moved += 1
            estimated += item.privateBytes
        case .deleted:
            deleted += 1
            estimated += item.privateBytes
        case .skipped: skipped += 1
        case .failed: failed += 1
        }
    }

    mutating func apply(finish line: HistoryLine) {
        finishedAt = line.at
        before = line.availableBefore
        after = line.availableAfter
    }

    var summary: CleanSummary {
        CleanSummary(
            id: id, startedAt: startedAt, finishedAt: finishedAt, mode: mode, plannedCount: planned,
            movedCount: moved, deletedCount: deleted, skippedCount: skipped, failedCount: failed,
            estimatedFreedBytes: estimated, availableBefore: before, availableAfter: after)
    }
}
