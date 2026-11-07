import CleanerScanner
import Foundation
import Observation

/// Drives the Space Lens page: scans a folder, keeps results per folder for the session, and tracks the
/// breadcrumb as the user drills down. Nothing starts until the user asks.
@Observable @MainActor
final class SpaceLensModel {
    /// Live numbers shown while a scan runs.
    struct ScanStatus: Equatable {
        var files = 0
        var bytes: Int64 = 0
        var currentPath: String?
    }

    enum State {
        case idle
        case scanning(ScanStatus)
        case ready(LensTree)
        case failed(String)
    }

    /// Walk settings from the brief: three levels of totals, no largest-files list.
    private static let walkOptions = WalkOptions(maxWorkers: 8, totalsDepth: 3, topFilesCount: 0)

    /// The folder the user chose. The breadcrumb starts here.
    private(set) var root: URL
    /// Folders from ``root`` down to the one on screen. Never empty.
    private(set) var path: [URL]
    private(set) var state: State = .idle

    @ObservationIgnored private var cache: [String: LensTree] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.root = root
        self.path = [root]
    }

    /// The folder on screen.
    var current: URL { path.last ?? root }

    /// True while a walk is running.
    var isScanning: Bool {
        if case .scanning = state { return true }
        return false
    }

    /// True when the center of the chart can go up one level.
    var canGoUp: Bool { path.count > 1 }

    /// Scans the current folder, or shows the cached result for it.
    func scan() {
        load(current)
    }

    /// Forgets every cached result and scans the current folder again.
    func rescan() {
        cache.removeAll()
        load(current)
    }

    /// Makes `url` the new root of the breadcrumb and scans it.
    func choose(_ url: URL) {
        root = url
        path = [url]
        load(url)
    }

    /// Opens a child folder: it joins the breadcrumb and is scanned (or taken from the cache).
    func explore(_ url: URL) {
        path.append(url)
        load(url)
    }

    /// Goes up one level in the breadcrumb.
    func goUp() {
        guard canGoUp else { return }
        path.removeLast()
        load(current)
    }

    /// Jumps to a breadcrumb entry.
    func navigate(toBreadcrumb index: Int) {
        guard path.indices.contains(index), index != path.count - 1 else { return }
        path = Array(path.prefix(index + 1))
        load(current)
    }

    /// Stops a running scan and returns to the idle page.
    func cancel() {
        guard isScanning else { return }
        task?.cancel()
        task = nil
        generation += 1
        state = .idle
    }

    // MARK: Loading

    private func load(_ url: URL) {
        task?.cancel()
        generation += 1
        let token = generation
        if let cached = cache[Self.cacheKey(url)] {
            task = nil
            state = .ready(cached)
            return
        }
        state = .scanning(ScanStatus())
        // Called from a walker thread, at most ten times a second.
        let onProgress: @Sendable (WalkProgress) -> Void = { [weak self] progress in
            let update = ScanStatus(
                files: progress.files, bytes: progress.allocatedBytes, currentPath: progress.currentPath?.path)
            Task { @MainActor in self?.report(update, token: token) }
        }
        task = Task { [weak self] in
            do {
                let result = try await BulkWalker.walk(url, options: Self.walkOptions, progress: onProgress)
                // A cancelled walk returns what it had. That is never shown as a result.
                guard !Task.isCancelled, !result.partial else { return }
                let tree = await LensTree.build(from: result)
                guard !Task.isCancelled else { return }
                self?.finish(tree, for: url, token: token)
            } catch let error as ScanError {
                self?.fail(error.userMessage, token: token)
            } catch {
                self?.fail("“\(url.lastPathComponent)” could not be scanned.", token: token)
            }
        }
    }

    private func report(_ progress: ScanStatus, token: Int) {
        guard token == generation, case .scanning = state else { return }
        state = .scanning(progress)
    }

    private func finish(_ tree: LensTree, for url: URL, token: Int) {
        guard token == generation else { return }
        cache[Self.cacheKey(url)] = tree
        state = .ready(tree)
    }

    private func fail(_ message: String, token: Int) {
        guard token == generation else { return }
        state = .failed(message)
    }

    private static func cacheKey(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
