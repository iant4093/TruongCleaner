import CleanerCore
import Darwin
import Foundation

/// Lists the apps installed in the application folders (`docs/UNINSTALLER.md` §1, §3).
///
/// Reads only. It looks at `/Applications` and `~/Applications` down to two levels, never follows a
/// symbolic link, and reads each app's `Info.plist` and code signature. If any folder or app cannot be
/// read in full the result says it is incomplete, and the matcher then leaves out matches that rest on names.
public enum AppInventory {
    /// The folders apps are installed in: `/Applications` and `~/Applications`.
    ///
    /// - Parameters:
    ///   - home: The user's home folder.
    ///   - system: The system applications folder. Tests pass a fixture folder.
    public static func defaultFolders(home: URL, system: URL = URL(filePath: "/Applications", directoryHint: .isDirectory)) -> [URL] {
        [system, home.appending(path: "Applications", directoryHint: .isDirectory)]
    }

    /// Largest `Info.plist` read.
    private static let infoPlistLimit = 1024 * 1024

    /// How many apps have their signature read at the same time.
    private static let parallelReads = 4

    /// Lists the apps in `folders`, sorted by name.
    ///
    /// A folder that does not exist counts as empty, so a missing `~/Applications` is normal. A folder
    /// or an app that cannot be read makes the result incomplete.
    ///
    /// - Parameter folders: The application folders.
    @concurrent
    public static func scan(folders: [URL]) async -> InstalledApps {
        var complete = true
        var bundles: [URL] = []
        for folder in folders {
            if Task.isCancelled { return InstalledApps(apps: [], isComplete: false) }
            let found = bundlesIn(folder)
            bundles.append(contentsOf: found.bundles)
            if !found.isComplete { complete = false }
        }

        var apps: [ReadResult] = []
        await withTaskGroup(of: ReadResult.self) { group in
            var next = 0
            while next < bundles.count, next < parallelReads {
                let index = next
                let bundle = bundles[index]
                group.addTask { read(index: index, bundle: bundle) }
                next += 1
            }
            while let result = await group.next() {
                apps.append(result)
                if next < bundles.count {
                    let index = next
                    let bundle = bundles[index]
                    group.addTask { read(index: index, bundle: bundle) }
                    next += 1
                }
            }
        }
        if apps.count < bundles.count { complete = false }
        if apps.contains(where: { !$0.complete }) { complete = false }
        let sorted = apps.sorted { $0.index < $1.index }.map(\.facts).sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        return InstalledApps(apps: sorted, isComplete: complete && !Task.isCancelled)
    }

    private struct ReadResult: Sendable {
        let index: Int
        let facts: AppFacts
        let complete: Bool
    }

    private static func read(index: Int, bundle: URL) -> ReadResult {
        let read = readFacts(at: bundle)
        return ReadResult(index: index, facts: read.facts, complete: read.complete)
    }

    /// The facts of one `.app`, for an app the user pointed at (for example by dropping it on the window).
    ///
    /// - Parameter bundle: The `.app` folder.
    /// - Returns: The facts, or nil when `bundle` is not a real folder ending in `.app` (a link is not followed).
    @concurrent
    public static func facts(at bundle: URL) async -> AppFacts? {
        var info = stat()
        let isFolder = bundle.withUnsafeFileSystemRepresentation { pointer -> Bool in
            guard let pointer else { return false }
            return lstat(pointer, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
        }
        guard isFolder, isApp(bundle.lastPathComponent) else { return nil }
        return readFacts(at: bundle).facts
    }

    /// The facts of one app, read synchronously. For one app the UI already knows about.
    ///
    /// - Returns: The facts, and false when anything about the app could not be read.
    static func readFacts(at bundle: URL) -> (facts: AppFacts, complete: Bool) {
        var complete = true
        var facts = AppFacts(url: bundle)

        switch SmallPlist.read(at: bundle.appending(path: "Contents/Info.plist"), limit: infoPlistLimit) {
        case .success(let plist):
            facts.bundleID = plist["CFBundleIdentifier"] as? String
            facts.name = plist["CFBundleName"] as? String
            facts.displayName = plist["CFBundleDisplayName"] as? String
            facts.executableName = plist["CFBundleExecutable"] as? String
            facts.version = (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String)
        case .failure:
            complete = false
        }

        let signing = AppSigning.read(bundle)
        facts.teamID = signing.teamID
        facts.signature = signing.signature

        var info = stat()
        let hasOwner = bundle.withUnsafeFileSystemRepresentation { pointer -> Bool in
            guard let pointer else { return false }
            return lstat(pointer, &info) == 0
        }
        if hasOwner { facts.ownerUID = UInt32(info.st_uid) } else { complete = false }

        let parent = bundle.deletingLastPathComponent()
        facts.parentIsWritable = parent.withUnsafeFileSystemRepresentation { pointer -> Bool? in
            guard let pointer else { return nil }
            return access(pointer, W_OK) == 0
        }
        return (facts, complete)
    }

    /// The `.app` folders directly in `folder` and one level below it. Links are skipped.
    private static func bundlesIn(_ folder: URL) -> (bundles: [URL], isComplete: Bool) {
        var bundles: [URL] = []
        var complete = true
        let top: FolderListing
        switch FolderReader.read(folder) {
        case .failure(let failure):
            return ([], failure.isMissing)
        case .success(let listing):
            top = listing
        }
        if !top.isComplete { complete = false }

        for entry in top.entries {
            guard let name = entry.name, entry.kind == .directory, !name.hasPrefix(".") else { continue }
            if isApp(name) {
                bundles.append(entry.url)
                continue
            }
            // One level down: vendor folders such as `/Applications/Utilities`.
            switch FolderReader.read(entry.url) {
            case .failure(let failure):
                if !failure.isMissing { complete = false }
            case .success(let inner):
                if !inner.isComplete { complete = false }
                for child in inner.entries where child.kind == .directory {
                    if let childName = child.name, isApp(childName) { bundles.append(child.url) }
                }
            }
        }
        return (bundles, complete)
    }

    private static func isApp(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".app")
    }
}

/// The measured size of one app.
public struct AppSize: Sendable, Hashable {
    /// The `.app` folder's path, matching `AppFacts.id`.
    public let appID: String
    /// Allocated bytes on disk, or nil when the app could not be measured.
    public let allocatedBytes: Int64?
    /// Bytes only this app owns (not shared with APFS clones).
    public let privateBytes: Int64?
    /// True when the walk was cut short or macOS refused some folders, so the size may be too low.
    public let isPartial: Bool
}

/// Measures app sizes lazily, a few at a time. Every walk takes its threads from the process-wide budget
/// (`WorkerBudget.shared`), so the walkers never use more than `min(6, activeProcessorCount)` threads.
///
/// Up to three walks run at once, each with up to two threads. Ask for any number of sizes; they queue.
public actor AppSizer {
    private let maxWalks: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Creates a sizer.
    ///
    /// - Parameter maxConcurrentWalks: Walks at once, 1 to 3. Each uses two threads.
    public init(maxConcurrentWalks: Int = 3) {
        self.maxWalks = max(1, min(3, maxConcurrentWalks))
    }

    /// Measures one app. Waits for a free slot first.
    ///
    /// - Parameter app: The `.app` folder.
    public func size(of app: URL) async -> AppSize {
        await acquire()
        let result = await Self.measure(app)
        release()
        return result
    }

    private func acquire() async {
        if running < maxWalks {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            // The slot passes straight to the next waiter.
            waiting.removeFirst().resume()
        }
    }

    @concurrent
    private static func measure(_ app: URL) async -> AppSize {
        let id = AppFacts.id(for: app)
        let options = WalkOptions(maxWorkers: 2, totalsDepth: 0, topFilesCount: 0)
        guard let result = try? await SharedBudgetWalk.walk(app, options: options), let root = result.nodes.first else {
            return AppSize(appID: id, allocatedBytes: nil, privateBytes: nil, isPartial: true)
        }
        return AppSize(
            appID: id, allocatedBytes: root.allocatedBytes, privateBytes: root.privateBytes,
            isPartial: result.partial || result.deniedCount > 0 || result.otherErrors > 0)
    }
}
