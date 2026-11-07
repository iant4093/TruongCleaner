import CleanerCore
import CleanerScanner
import Foundation
import Observation
import UniformTypeIdentifiers

/// One line in the results table. Plain values only; built off the main actor.
nonisolated struct LargeFileRow: Identifiable, Sendable {
    let id: EntryID
    let url: URL
    let name: String
    let kind: String
    let allocatedBytes: Int64
    let modified: Date?
    /// Sort key for the Modified column. Files with an unknown date sort as the oldest.
    let modifiedSort: Date
    /// Parent folder with the home folder shown as `~`.
    let location: String

    init(file: LargeFile) {
        id = file.id
        url = file.url
        name = file.url.lastPathComponent
        kind = Self.kind(forExtension: file.url.pathExtension)
        allocatedBytes = file.allocatedBytes
        modified = file.modified
        modifiedSort = file.modified ?? .distantPast
        location = Self.abbreviate(file.url.deletingLastPathComponent().path)
    }

    /// A path with the home folder replaced by `~`.
    static func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private static func kind(forExtension ext: String) -> String {
        guard !ext.isEmpty else { return "Document" }
        return UTType(filenameExtension: ext)?.localizedDescription ?? "\(ext.uppercased()) file"
    }
}

/// Smallest size that counts as large. Decimal units, like Finder.
enum MinimumFileSize: String, CaseIterable, Identifiable {
    case mb50, mb100, mb500, gb1

    var id: Self { self }

    var title: String {
        switch self {
        case .mb50: "50 MB"
        case .mb100: "100 MB"
        case .mb500: "500 MB"
        case .gb1: "1 GB"
        }
    }

    var bytes: Int64 {
        switch self {
        case .mb50: 50_000_000
        case .mb100: 100_000_000
        case .mb500: 500_000_000
        case .gb1: 1_000_000_000
        }
    }
}

/// How long a file must have been left alone to be listed.
enum UntouchedPeriod: String, CaseIterable, Identifiable {
    case anyTime, days30, days90, year1

    var id: Self { self }

    var title: String {
        switch self {
        case .anyTime: "Any time"
        case .days30: "30 days"
        case .days90: "90 days"
        case .year1: "1 year"
        }
    }

    /// Files modified after this date are left out. `nil` means no limit.
    func cutoff(now: Date = .now) -> Date? {
        let days: Int
        switch self {
        case .anyTime: return nil
        case .days30: days = 30
        case .days90: days = 90
        case .year1: days = 365
        }
        return Calendar.current.date(byAdding: .day, value: -days, to: now)
    }
}

/// Runs the large-file search and holds what the page shows. All file reading happens in the kit, off the main actor.
@Observable @MainActor
final class LargeFilesModel {
    /// What a finished search found out besides the files.
    struct Outcome {
        var partial = false
        var mayBeMissingFiles = false
        var needsAccess: [URL] = []
        var skippedFolders: [URL] = []
        /// Set when no folder could be searched at all.
        var failureMessage: String?
    }

    enum Phase {
        case idle
        case searching(filesChecked: Int)
    }

    static let foldersKey = "largeFiles.folders"
    /// Most rows shown. The kit keeps a longer candidate list behind this.
    static let resultLimit = 500

    /// Folders to search. Saved whenever they change.
    private(set) var folders: [URL] {
        didSet { defaults.set(folders.map(\.path), forKey: Self.foldersKey) }
    }

    var minimumSize: MinimumFileSize = .mb100
    var untouchedPeriod: UntouchedPeriod = .days90
    var selection: Set<EntryID> = []
    var sortOrder: [KeyPathComparator<LargeFileRow>] {
        didSet { rows.sort(using: sortOrder) }
    }

    private(set) var rows: [LargeFileRow] = []
    private(set) var totalBytes: Int64 = 0
    private(set) var phase: Phase = .idle
    /// `nil` until a search has finished. Cleared when a new search starts.
    private(set) var outcome: Outcome?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sortOrder = [KeyPathComparator(\.allocatedBytes, order: .reverse)]
        if let saved = defaults.stringArray(forKey: Self.foldersKey) {
            folders = saved.map { URL(filePath: $0, directoryHint: .isDirectory) }
        } else {
            folders = ["Downloads", "Documents", "Desktop", "Movies"].map {
                URL.homeDirectory.appending(path: $0, directoryHint: .isDirectory)
            }
        }
    }

    var isSearching: Bool {
        if case .searching = phase { true } else { false }
    }

    // MARK: Folders

    /// Adds folders that are not in the list yet.
    func addFolders(_ urls: [URL]) {
        var known = Set(folders.map(\.standardizedFileURL.path))
        for url in urls where known.insert(url.standardizedFileURL.path).inserted {
            folders.append(url)
        }
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0 == url }
    }

    // MARK: Search

    /// Starts a search with the current folders and filters. Does nothing while one is running.
    func find() {
        guard !isSearching, !folders.isEmpty else { return }
        phase = .searching(filesChecked: 0)
        outcome = nil
        rows = []
        totalBytes = 0
        selection = []
        searchTask = Task { await run() }
    }

    /// Stops the running search. The files found so far are kept and marked as partial.
    func stop() {
        searchTask?.cancel()
    }

    /// The URLs of the given rows, in table order.
    func urls(for ids: Set<EntryID>) -> [URL] {
        rows.filter { ids.contains($0.id) }.map(\.url)
    }

    private func run() async {
        let query = LargeFileQuery(
            roots: folders, minBytes: minimumSize.bytes,
            notModifiedSince: untouchedPeriod.cutoff(), limit: Self.resultLimit)

        // Newest progress only; the walker already limits updates to about ten a second.
        let (stream, continuation) = AsyncStream.makeStream(
            of: LargeFileProgress.self, bufferingPolicy: .bufferingNewest(1))
        let reader = Task {
            for await progress in stream {
                self.phase = .searching(filesChecked: progress.files)
            }
        }

        var finished = Outcome()
        var found: [LargeFileRow] = []
        do {
            let report = try await LargeFileFinder.search(query) { continuation.yield($0) }
            finished.partial = report.partial
            finished.mayBeMissingFiles = report.mayBeMissingFiles
            finished.needsAccess = report.needsAccess
            finished.skippedFolders = report.skippedRoots
            found = await Self.makeRows(report.files)
        } catch let error as ScanError {
            finished.failureMessage = error.userMessage
            finished.needsAccess = error.isAccessDenied ? [error.url] : []
        } catch {
            finished.failureMessage = "The search could not finish."
        }
        continuation.finish()
        await reader.value

        found.sort(using: sortOrder)
        rows = found
        totalBytes = found.reduce(0) { $0 + $1.allocatedBytes }
        outcome = finished
        phase = .idle
        searchTask = nil
    }

    @concurrent
    private static func makeRows(_ files: [LargeFile]) async -> [LargeFileRow] {
        files.map { LargeFileRow(file: $0) }
    }
}

private extension ScanError {
    var isAccessDenied: Bool {
        if case .accessDenied = self { true } else { false }
    }

    var url: URL {
        switch self {
        case .notADirectory(let url), .accessDenied(let url), .cannotOpen(let url, _): url
        }
    }
}
