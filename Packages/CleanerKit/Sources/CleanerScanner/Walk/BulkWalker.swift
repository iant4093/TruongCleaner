import Darwin
import Foundation
import os

/// Walks a folder tree with `getattrlistbulk` and reports allocated and private sizes.
///
/// The walker reads only. It never follows symbolic links, never crosses into
/// another volume (compared by `f_fsid`, because `ATTR_CMN_FSID` is the same on the System and Data
/// volumes; mount points are skipped before they are opened), counts each hard-linked file
/// once, and reports folders it was not allowed to open instead of counting
/// them as empty. It keeps one total per folder down to `totalsDepth` and no
/// object per file below that.
public enum BulkWalker {
    private static let log = Logger(subsystem: "com.iant4093.TruongCleaner", category: "scanner")

    /// Walks `root` off the main actor and returns its totals.
    ///
    /// Work runs on up to `options.maxWorkers` threads and the caller is not blocked. When the calling task is
    /// cancelled, or `options.limit` passes, the walk stops within about 100 ms and returns what it has with
    /// `partial == true`.
    ///
    /// - Parameters:
    ///   - root: The folder to walk. It must be a real folder, not a symbolic link.
    ///   - options: Workers, totals depth, largest-files count and limits.
    ///   - progress: Called at most once per `options.progressInterval`, never from two threads at once.
    ///     It runs on a worker thread, so keep it short.
    /// - Throws: `ScanError.notADirectory` if `root` is a symlink or not a folder, `ScanError.accessDenied`
    ///   if macOS refuses access to `root`, `ScanError.cannotOpen` for other failures to open it.
    @concurrent
    public static func walk(
        _ root: URL, options: WalkOptions,
        progress: (@Sendable (WalkProgress) -> Void)? = nil
    ) async throws -> WalkResult {
        let stop = StopControl(limit: options.limit)
        return try await withTaskCancellationHandler {
            let run = try WalkRun.prepare(root: root, options: options, progress: progress, stop: stop)
            let result = await run.execute()
            log.debug(
                "walk finished: \(result.files) files, \(result.directories) folders, partial \(result.partial), root \(root.path, privacy: .private)"
            )
            return result
        } onCancel: {
            stop.cancel()
        }
    }
}

/// One walk in progress. Created after the root has been opened; owns the root descriptor until a worker takes it.
private final class WalkRun: Sendable {
    let root: URL
    let volume: UInt64
    let context: WalkContext
    /// Threads to start with.
    let workers: Int
    /// Most threads the walk may have at once.
    let maxWorkers: Int
    let budget: WorkerBudget?

    private init(root: URL, volume: UInt64, context: WalkContext, workers: Int, maxWorkers: Int, budget: WorkerBudget?) {
        self.root = root
        self.volume = volume
        self.context = context
        self.workers = workers
        self.maxWorkers = maxWorkers
        self.budget = budget
    }

    /// Checks and opens the root, then builds the shared state. Throws before anything is started.
    static func prepare(
        root: URL, options: WalkOptions, progress: (@Sendable (WalkProgress) -> Void)?, stop: StopControl
    ) throws -> WalkRun {
        FileLimit.ensureMinimum()
        guard let path = rootPath(of: root) else { throw ScanError.cannotOpen(root, errno: EINVAL) }

        // lstat first: a symlink root is rejected, never followed.
        var linkInfo = stat()
        guard lstat(path, &linkInfo) == 0 else {
            throw openError(for: root, code: errno)
        }
        guard linkInfo.st_mode & S_IFMT == S_IFDIR else { throw ScanError.notADirectory(root) }

        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw openError(for: root, code: errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, let rootFSID = attributeFSID(of: fd), let rootVolume = volumeIdentity(of: fd) else {
            let code = errno
            close(fd)
            throw openError(for: root, code: code)
        }

        let maxWorkers = max(
            1, min(options.maxWorkers, WorkerBudget.processWideTotal))
        // With a shared budget the walk starts with the one thread the caller holds for it and grows.
        let budget = options.budget
        let workers = budget == nil ? maxWorkers : 1
        let nodes = SizeAccumulator()
        var rootTotals = Totals()
        rootTotals.note(
            time: packTime(seconds: Int64(info.st_mtimespec.tv_sec), nanoseconds: Int64(info.st_mtimespec.tv_nsec)))
        let rootIndex = nodes.addNode(
            NodeRecord(
                url: makeURL(fromPath: path, isDirectory: true), depth: 0,
                id: EntryID(fsid: rootFSID, fileID: UInt64(info.st_ino)), kind: .directory, flags: info.st_flags,
                parent: 0),
            initial: rootTotals)

        let queue = JobQueue()
        queue.push(
            WalkJob(
                fd: fd, path: path, depth: 0, keptNode: rootIndex,
                descent: options.descent?.rootCursor ?? .everything))
        let context = WalkContext(
            queue: queue, links: HardLinkSet(), nodes: nodes, denied: DeniedList(), stop: stop,
            progress: ProgressReporter(interval: options.progressInterval, callback: progress),
            rootFSID: rootFSID, rootVolume: rootVolume, totalsDepth: max(0, options.totalsDepth),
            topFilesCapacity: max(0, options.topFilesCount),
            handoffLimit: maxWorkers > 1 ? maxWorkers : 0,
            prune: PrunePlan(options), descent: options.descent,
            extras: budget == nil || maxWorkers == 1 ? nil : ExtraWorkers())
        return WalkRun(
            root: root, volume: rootVolume, context: context, workers: workers, maxWorkers: maxWorkers, budget: budget)
    }

    /// Runs the workers and waits without blocking a cooperative thread.
    func execute() async -> WalkResult {
        let context = self.context
        return await withCheckedContinuation { continuation in
            let group = WalkGroup(
                budget: budget, maxThreads: maxWorkers,
                body: { DirectoryWalker.work(context: context) },
                onFinished: { outputs in
                    // The walk is over: drop the link from the context back to the thread group.
                    context.extras?.install(nil)
                    continuation.resume(returning: self.assemble(outputs))
                })
            context.extras?.install(group)
            group.start(workers: workers)
        }
    }

    /// Merges the workers' results. Runs once, on the last worker thread.
    private func assemble(_ outputs: [WorkerOutput]) -> WalkResult {
        var counters = WalkCounters()
        for output in outputs { counters.merge(output.counters) }
        counters.directories += 1  // the root

        // After a stop, jobs may still be queued. Close their descriptors.
        let leftover = context.queue.drain()
        for job in leftover { close(job.fd) }
        if !leftover.isEmpty { context.stop.markIncomplete() }

        let denied = context.denied.snapshot()
        return WalkResult(
            root: root,
            volume: volume,
            nodes: context.nodes.finish(),
            topFiles: TopFiles.merge(outputs.map(\.top), capacity: context.topFilesCapacity),
            files: counters.files,
            directories: counters.directories,
            symlinks: counters.symlinks,
            hardLinkDuplicates: counters.hardLinkDuplicates,
            crossVolumeSkipped: counters.crossVolumeSkipped,
            deniedDirectories: denied.urls,
            deniedCount: denied.count,
            otherErrors: counters.otherErrors,
            privateSizeMissing: counters.privateSizeMissing,
            partial: context.stop.isIncomplete)
    }

    private static func rootPath(of url: URL) -> [CChar]? {
        url.withUnsafeFileSystemRepresentation { pointer -> [CChar]? in
            guard let pointer else { return nil }
            return Array(UnsafeBufferPointer(start: pointer, count: strlen(pointer) + 1))
        }
    }

    private static func openError(for root: URL, code: Int32) -> ScanError {
        switch code {
        case EPERM, EACCES: .accessDenied(root)
        case ENOTDIR, ELOOP: .notADirectory(root)
        default: .cannotOpen(root, errno: code)
        }
    }
}
