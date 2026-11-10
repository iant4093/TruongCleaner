import Darwin
import Foundation
import os

/// The result of walking one folder for the category scan.
private enum WalkOutcome {
    case walked(WalkResult)
    /// macOS refused to open the folder.
    case denied
    /// The folder does not exist (or is not a folder), so there is nothing to count.
    case absent
    /// The folder could not be opened for another reason. The measurement is incomplete.
    case failed
}

/// Bytes the Library walk assigned to each category, and the folders it was not allowed to open.
struct LibrarySplit: Sendable {
    var bytes: [StorageCategory: Int64] = [:]
    var privateBytes: [StorageCategory: Int64] = [:]
    var denied: [StorageCategory: Int] = [:]
}

/// One category measurement in progress. Walks run one after another on the process-wide thread budget
/// (`WorkerBudget.shared`, `min(6, activeProcessorCount)`), together with every other scan in the process.
struct CategoryRun {
    private static let log = Logger(subsystem: "com.iant4093.TruongCleaner", category: "categories")

    private let workers: Int
    private let progress: (@Sendable (CategoryProgress) -> Void)?
    private var bytes: [StorageCategory: Int64] = [:]
    private var privateBytes: [StorageCategory: Int64] = [:]
    private var needsAccess: [StorageCategory: Int] = [:]
    private var partial = false
    private var measuredTotal: Int64 = 0

    init(progress: (@Sendable (CategoryProgress) -> Void)?) {
        self.workers = WorkerBudget.processWideTotal
        self.progress = progress
    }

    func totals(duration: Duration) -> CategoryTotals {
        CategoryTotals(
            bytes: bytes, privateBytes: privateBytes, needsAccess: needsAccess,
            partial: partial, duration: duration)
    }

    // MARK: Steps

    /// Measures a whole folder as one category. A missing folder counts as nothing.
    mutating func measureFolder(_ url: URL, as category: StorageCategory) async {
        guard !stopped() else { return }
        switch await walk(url, category: category, totalsDepth: 0) {
        case .walked(let result):
            add(result, to: category)
        case .denied:
            needsAccess[category, default: 0] += 1
        case .absent:
            break
        case .failed:
            partial = true
        }
    }

    /// Measures the home folder. Every direct child is walked on its own, so a named folder goes to its
    /// category and nothing is counted twice. `Library` is walked once and split by ``CategoryPlan``.
    mutating func measureHome(_ home: URL) async {
        let listing: ChildListing
        switch ChildListing.read(home) {
        case .success(let value): listing = value
        case .failure(let failure):
            if failure.isDenied { needsAccess[.otherHome, default: 0] += 1 } else if !failure.isMissing { partial = true }
            return
        }
        if listing.unreadable > 0 { partial = true }
        for name in listing.deniedNames {
            needsAccess[CategoryPlan.homeCategory(forFolder: name) ?? .otherHome, default: 0] += 1
        }
        let homeDevice = ChildListing.identity(of: home)?.device

        for child in listing.entries {
            guard !stopped() else { return }
            guard child.isDirectory else {
                count(child.allocatedBytes, in: .otherHome)
                continue
            }
            // A volume mounted inside the home folder (a disk image, a share) is not Data-volume space.
            if let homeDevice, child.device != homeDevice { continue }
            if child.name == "Library" {
                await measureLibrary(child)
            } else {
                await measureFolder(child.url, as: CategoryPlan.homeCategory(forFolder: child.name) ?? .otherHome)
            }
        }
    }

    /// Measures every folder under `usersRoot` except the one that is `home`.
    mutating func measureOtherUsers(_ usersRoot: URL, skipping home: URL) async {
        let listing: ChildListing
        switch ChildListing.read(usersRoot) {
        case .success(let value): listing = value
        case .failure(let failure):
            if failure.isDenied { needsAccess[.otherUsers, default: 0] += 1 } else if !failure.isMissing { partial = true }
            return
        }
        if listing.unreadable > 0 { partial = true }
        needsAccess[.otherUsers, default: 0] += listing.deniedNames.count
        let homeIdentity = ChildListing.identity(of: home)
        let usersDevice = ChildListing.identity(of: usersRoot)?.device

        for child in listing.entries {
            guard !stopped() else { return }
            if let homeIdentity, child.device == homeIdentity.device, child.inode == homeIdentity.inode { continue }
            // A volume mounted under /Users is not Data-volume space, so it stays out of "Other users".
            if let usersDevice, child.device != usersDevice { continue }
            if child.isDirectory {
                await measureFolder(child.url, as: .otherUsers)
            } else {
                count(child.allocatedBytes, in: .otherUsers)
            }
        }
    }

    // MARK: Library

    private mutating func measureLibrary(_ library: ChildEntry) async {
        switch await walk(library.url, category: .libraryOther, totalsDepth: CategoryPlan.libraryTotalsDepth) {
        case .walked(let result):
            let split = Self.splitLibrary(result)
            for (category, value) in split.bytes { count(value, private: split.privateBytes[category] ?? value, in: category) }
            for (category, value) in split.denied { needsAccess[category, default: 0] += value }
            noteIncomplete(result, what: "library walk")
        case .denied:
            needsAccess[.libraryOther, default: 0] += 1
        case .absent:
            break
        case .failed:
            partial = true
        }
    }

    /// Splits one Library walk into categories.
    ///
    /// The walk keeps a total for every folder down to the deepest carve-out. Each carve-out's total is
    /// assigned to its category and subtracted from the Library total; what remains is `libraryOther`.
    /// Subtracting (rather than walking the rest in pieces) reads each file once and costs one walk.
    static func splitLibrary(_ result: WalkResult) -> LibrarySplit {
        var split = LibrarySplit()
        guard let root = result.nodes.first(where: { $0.depth == 0 }) else { return split }

        var otherBytes = root.allocatedBytes
        var otherPrivate = root.privateBytes
        for node in result.nodes where node.depth >= 1 && node.depth <= CategoryPlan.libraryTotalsDepth {
            let relative = CategoryPlan.normalized(node.url.pathComponents.suffix(node.depth)).joined(separator: "/")
            guard let category = CategoryPlan.libraryCarveOuts[relative] else { continue }
            split.bytes[category, default: 0] += node.allocatedBytes
            split.privateBytes[category, default: 0] += node.privateBytes
            otherBytes -= node.allocatedBytes
            otherPrivate -= node.privateBytes
        }
        split.bytes[.libraryOther] = max(0, otherBytes)
        split.privateBytes[.libraryOther] = max(0, otherPrivate)

        // Denied folders are mapped by their path below Library. Folders past the list's cap go to `libraryOther`.
        let rootDepth = root.url.pathComponents.count
        for url in result.deniedDirectories {
            let relative = CategoryPlan.normalized(url.pathComponents.dropFirst(rootDepth))
            split.denied[CategoryPlan.libraryCategory(forRelative: relative), default: 0] += 1
        }
        let unlisted = result.deniedCount - result.deniedDirectories.count
        if unlisted > 0 { split.denied[.libraryOther, default: 0] += unlisted }
        return split
    }

    // MARK: Helpers

    private mutating func stopped() -> Bool {
        if Task.isCancelled {
            partial = true
            return true
        }
        return false
    }

    private mutating func add(_ result: WalkResult, to category: StorageCategory) {
        let root = result.nodes.first
        count(root?.allocatedBytes ?? 0, private: root?.privateBytes, in: category)
        if result.deniedCount > 0 { needsAccess[category, default: 0] += result.deniedCount }
        noteIncomplete(result, what: "walk")
    }

    /// A walk that stopped early, or dropped entries for a reason other than permission, undercounts:
    /// the category total is "at least" what was found, so the whole measurement is partial.
    private mutating func noteIncomplete(_ result: WalkResult, what: String) {
        if result.otherErrors > 0 { Self.log.debug("\(what) had \(result.otherErrors) other errors") }
        if result.isIncomplete { partial = true }
    }

    private mutating func count(_ allocated: Int64, private privateSize: Int64? = nil, in category: StorageCategory) {
        bytes[category, default: 0] += allocated
        privateBytes[category, default: 0] += privateSize ?? allocated
        measuredTotal += allocated
    }

    private func walk(_ url: URL, category: StorageCategory, totalsDepth: Int) async -> WalkOutcome {
        let base = measuredTotal
        var callback: (@Sendable (WalkProgress) -> Void)?
        if let report = progress {
            callback = { @Sendable walkProgress in
                report(CategoryProgress(category: category, measuredBytes: base + walkProgress.allocatedBytes))
            }
        }
        do {
            let result = try await SharedBudgetWalk.walk(
                url, options: WalkOptions(maxWorkers: workers, totalsDepth: totalsDepth), progress: callback)
            return .walked(result)
        } catch let error as ScanError {
            switch error {
            case .accessDenied: return .denied
            case .notADirectory: return .absent
            case .cannotOpen(_, let code): return code == ENOENT ? .absent : .failed
            }
        } catch {
            return .failed
        }
    }
}
