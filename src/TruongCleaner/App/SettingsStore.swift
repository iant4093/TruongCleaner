import CleanerCore
import Foundation
import Observation
import os

/// What a clean does with items by default (`docs/UI.md` §4.8).
enum DeleteModeSetting: String, CaseIterable, Identifiable {
    /// Move items to the Trash. The default.
    case trash
    /// Delete immediately. Each clean still asks for a second confirmation.
    case permanent

    var id: Self { self }

    var title: String {
        switch self {
        case .trash: "Move to Trash"
        case .permanent: "Delete immediately"
        }
    }
}

/// Reads and writes `exclusions.json` (an array of absolute paths) off the main actor.
actor ExclusionsStorage {
    enum LoadResult: Sendable {
        case loaded([URL])
        /// The file exists but could not be read or understood. Not the same as "no exclusions".
        case unreadable
    }

    private static let log = Logger(subsystem: "com.iant4093.TruongCleaner", category: "settings")

    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Default location: `~/Library/Application Support/TruongCleaner/exclusions.json`.
    static func defaultFileURL() -> URL {
        URL.applicationSupportDirectory
            .appending(path: "TruongCleaner", directoryHint: .isDirectory)
            .appending(path: "exclusions.json", directoryHint: .notDirectory)
    }

    func load() -> LoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .loaded([])
        } catch {
            Self.log.error("Could not read exclusions: \(error.localizedDescription, privacy: .public)")
            return .unreadable
        }
        guard let paths = try? JSONDecoder().decode([String].self, from: data) else {
            Self.log.error("Exclusions file is not a JSON array of strings")
            return .unreadable
        }
        // Only absolute paths count. Anything else would be resolved against an unknown folder.
        let urls = paths.filter { $0.hasPrefix("/") }.map { URL(filePath: $0, directoryHint: .isDirectory) }
        if urls.count != paths.count { return .unreadable }
        return .loaded(urls)
    }

    func save(_ urls: [URL]) {
        do {
            let folder = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let paths = urls.map { $0.path(percentEncoded: false) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(paths).write(to: fileURL, options: .atomic)
        } catch {
            Self.log.error("Could not save exclusions: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// App settings that scans and cleans read: delete mode, folder exclusions, disabled rules,
/// and the update-check switch.
///
/// Simple values live in `UserDefaults`. Exclusions live in a JSON file and are read and
/// written off the main actor. Not named `Settings`, which is the SwiftUI scene type.
@Observable @MainActor
final class SettingsStore {
    /// `UserDefaults` key for the disabled rule IDs, a JSON array of strings (what `@AppStorage` reads).
    static let disabledRulesKey = "disabledRules"
    static let deleteModeKey = "deleteMode"
    static let autoUpdateCheckKey = "checkForUpdatesAutomatically"

    /// How cleans remove items.
    var deleteMode: DeleteModeSetting {
        didSet { defaults.set(deleteMode.rawValue, forKey: Self.deleteModeKey) }
    }

    /// Whether the app asks GitHub once a day if a newer build exists.
    var checksForUpdatesAutomatically: Bool {
        didSet { defaults.set(checksForUpdatesAutomatically, forKey: Self.autoUpdateCheckKey) }
    }

    /// IDs of rules the user turned off.
    private(set) var disabledRuleIDs: Set<String>

    /// Folders the user excluded. Nothing inside or above them is offered or cleaned.
    private(set) var exclusions: [URL] = []

    /// True when `exclusions.json` exists but could not be read. Scans must not run in this state.
    private(set) var exclusionsUnreadable = false

    /// The catalog this store filters.
    let catalog: [Rule]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storage: ExclusionsStorage
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Creates the store and starts reading the exclusions file.
    init(
        catalog: [Rule] = Catalog.all,
        defaults: UserDefaults = .standard,
        exclusionsFile: URL = ExclusionsStorage.defaultFileURL()
    ) {
        self.catalog = catalog
        self.defaults = defaults
        self.storage = ExclusionsStorage(fileURL: exclusionsFile)
        self.deleteMode = defaults.string(forKey: Self.deleteModeKey).flatMap(DeleteModeSetting.init) ?? .trash
        self.checksForUpdatesAutomatically = defaults.object(forKey: Self.autoUpdateCheckKey) as? Bool ?? true
        self.disabledRuleIDs = Self.readDisabledRules(from: defaults)
        self.loadTask = Task { [storage] in
            let result = await storage.load()
            self.applyLoaded(result)
        }
    }

    // MARK: Scans and gates

    /// Rules that are turned on, in catalog order. Pass these to `ScanRequest.rules`.
    var enabledRules: [Rule] {
        catalog.filter { !disabledRuleIDs.contains($0.id) }
    }

    /// The exclusions once the file has been read, for `ScanRequest.userExclusions` and
    /// `PathPolicy(environment:userExclusions:)`. Returns `nil` when the file cannot be read:
    /// unknown means keep, so the caller must not scan or clean.
    func loadedExclusions() async -> [URL]? {
        await loadTask?.value
        return exclusionsUnreadable ? nil : exclusions
    }

    // MARK: Rules

    /// Whether a rule is on.
    func isEnabled(_ rule: Rule) -> Bool {
        !disabledRuleIDs.contains(rule.id)
    }

    /// Turns one rule on or off and saves the choice.
    func setEnabled(_ enabled: Bool, for rule: Rule) {
        if enabled {
            disabledRuleIDs.remove(rule.id)
        } else {
            disabledRuleIDs.insert(rule.id)
        }
        saveDisabledRules()
    }

    /// Rules of one category, in catalog order.
    func rules(in category: CleanerCore.Category) -> [Rule] {
        catalog.filter { $0.category == category }
    }

    /// Categories that have at least one rule, in `Category.allCases` order.
    var categories: [CleanerCore.Category] {
        CleanerCore.Category.allCases.filter { category in catalog.contains { $0.category == category } }
    }

    /// True when any rule of the category is on.
    func isCategoryEnabled(_ category: CleanerCore.Category) -> Bool {
        rules(in: category).contains(where: isEnabled)
    }

    /// Turns every rule of a category on or off.
    func setCategory(_ category: CleanerCore.Category, enabled: Bool) {
        for rule in rules(in: category) {
            if enabled {
                disabledRuleIDs.remove(rule.id)
            } else {
                disabledRuleIDs.insert(rule.id)
            }
        }
        saveDisabledRules()
    }

    // MARK: Exclusions

    /// Adds folders to the exclusion list. Duplicates are ignored. Does nothing while the saved
    /// list is unreadable, so a bad file is never overwritten by accident.
    func addExclusions(_ urls: [URL]) {
        guard !exclusionsUnreadable else { return }
        var changed = false
        for url in urls {
            let folder = url.standardizedFileURL
            guard folder.isFileURL, !exclusions.contains(where: { $0.path == folder.path }) else { continue }
            exclusions.append(folder)
            changed = true
        }
        if changed { persistExclusions() }
    }

    /// Removes a folder from the exclusion list.
    func removeExclusion(_ url: URL) {
        guard !exclusionsUnreadable else { return }
        let before = exclusions.count
        exclusions.removeAll { $0.path == url.path }
        if exclusions.count != before { persistExclusions() }
    }

    /// Replaces an unreadable exclusions file with an empty list, after the user asked for it.
    func startNewExclusionList() {
        exclusions = []
        exclusionsUnreadable = false
        persistExclusions()
    }

    // MARK: Private

    private func applyLoaded(_ result: ExclusionsStorage.LoadResult) {
        switch result {
        case .loaded(let urls):
            // Folders added before the read finished stay.
            let added = exclusions.filter { new in !urls.contains { $0.path == new.path } }
            exclusions = urls + added
            exclusionsUnreadable = false
        case .unreadable:
            exclusionsUnreadable = true
        }
    }

    private func persistExclusions() {
        let snapshot = exclusions
        let previous = saveTask
        saveTask = Task { [storage] in
            await previous?.value
            await storage.save(snapshot)
        }
    }

    private func saveDisabledRules() {
        guard let data = try? JSONEncoder().encode(disabledRuleIDs.sorted()),
              let text = String(data: data, encoding: .utf8) else { return }
        defaults.set(text, forKey: Self.disabledRulesKey)
    }

    private static func readDisabledRules(from defaults: UserDefaults) -> Set<String> {
        guard let text = defaults.string(forKey: disabledRulesKey),
              let ids = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) else { return [] }
        return Set(ids)
    }
}
