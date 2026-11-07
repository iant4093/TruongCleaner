import CleanerActions
import CleanerCore
import Darwin
import Foundation

/// Objects the whole app shares: the one history store and the helpers that build a `Cleaner`.
///
/// Every page that cleans, puts items back or reads history uses `AppModel.services`, so
/// there is a single writer for `history.jsonl`.
nonisolated struct Services: Sendable {
    /// The record of every clean, at `~/Library/Application Support/TruongCleaner/history.jsonl`.
    let history: HistoryStore

    /// Creates the services. Tests and previews can pass another history file.
    init(historyFile: URL = Services.defaultHistoryFile()) {
        history = HistoryStore(fileURL: historyFile)
    }

    /// `~/Library/Application Support/TruongCleaner/history.jsonl`.
    static func defaultHistoryFile() -> URL {
        URL.applicationSupportDirectory
            .appending(path: "TruongCleaner", directoryHint: .isDirectory)
            .appending(path: "history.jsonl", directoryHint: .notDirectory)
    }

    /// Home folder, Darwin directories and the clock, as the scanner and the gate need them.
    static func makeEnvironment() -> CleanerCore.Environment {
        CleanerCore.Environment(
            home: FileManager.default.homeDirectoryForCurrentUser,
            darwinUserCache: darwinDirectory(_CS_DARWIN_USER_CACHE_DIR),
            darwinUserTemp: darwinDirectory(_CS_DARWIN_USER_TEMP_DIR),
            now: Date()
        )
    }

    /// The Trash folders `UndoService` may act in.
    static func trashLocations(home: URL) -> TrashLocations {
        TrashLocations(home: home)
    }

    /// A `Cleaner` that moves or deletes through `FileManagerExecutor`, behind `SafetyGate`, and
    /// writes to the shared history.
    ///
    /// Owners are answered by process name only. A rule whose owner is a bundle ID is kept
    /// ("owner unknown") by the gate, which is the safe answer. The Smart Clean page supplies
    /// its own app-aware provider.
    ///
    /// - Parameters:
    ///   - environment: Home folder and clock.
    ///   - userExclusions: Folders from Settings. The gate refuses anything in or above them.
    func makeCleaner(environment: CleanerCore.Environment, userExclusions: [URL]) -> Cleaner {
        let policy = PathPolicy(environment: environment, userExclusions: userExclusions)
        return Cleaner(
            gate: SafetyGate(),
            executor: FileManagerExecutor(),
            history: history,
            context: { planned in
                GateContext(
                    environment: environment,
                    policy: policy,
                    expandedRoots: planned.expandedRoots,
                    runningApps: ProcessNameOwnerProvider(
                        roots: planned.expandedRoots, rootSpecs: planned.rule.roots),
                    openFiles: ProcessOpenFilesProvider(),
                    allowWholeBundle: false,
                    rootOwners: [:]
                )
            }
        )
    }

    /// The value of a `confstr` directory such as `_CS_DARWIN_USER_CACHE_DIR`, or nil if unreadable.
    private static func darwinDirectory(_ name: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = confstr(name, &buffer, buffer.count)
        guard length > 1, length <= buffer.count else { return nil }
        // `length` counts the terminating NUL.
        let path = String(decoding: buffer.prefix(length - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(filePath: path, directoryHint: .isDirectory)
    }
}
