import Darwin
import Foundation
import Synchronization
import os

/// Counters kept per worker and merged at the end. No per-file objects exist anywhere.
struct Counters: Sendable {
    var files = 0
    var dirs = 0
    var symlinks = 0
    var hardlinkDupesSkipped = 0
    var permissionDenied = 0
    var otherErrors = 0
    var crossDeviceSkipped = 0
    var allocatedBytes: Int64 = 0

    mutating func merge(_ other: Counters) {
        files += other.files
        dirs += other.dirs
        symlinks += other.symlinks
        hardlinkDupesSkipped += other.hardlinkDupesSkipped
        permissionDenied += other.permissionDenied
        otherErrors += other.otherErrors
        crossDeviceSkipped += other.crossDeviceSkipped
        allocatedBytes += other.allocatedBytes
    }

    /// Classifies a POSIX errno: EPERM/EACCES are "needs access", never silently zero.
    mutating func record(errno code: Int32) {
        if code == EPERM || code == EACCES {
            permissionDenied += 1
        } else {
            otherErrors += 1
        }
    }
}

/// `(device, fileID)` identity used to count hard-linked files once.
struct LinkKey: Hashable, Sendable {
    let device: UInt32
    let fileID: UInt64
}

/// Set of hard-linked files already counted. Only entries with link count > 1 touch it.
final class HardLinks<Key: Hashable & Sendable>: Sendable {
    private let seen = OSAllocatedUnfairLock<Set<Key>>(initialState: [])

    /// Returns true the first time `key` is seen.
    func firstSighting(_ key: Key) -> Bool {
        seen.withLock { $0.insert(key).inserted }
    }
}

/// Deadline plus a shared stop flag. `tripped` means some work was skipped.
final class StopControl: Sendable {
    private let flag = Atomic<Bool>(false)
    private let deadline: ContinuousClock.Instant?

    init(limitSeconds: Double?) {
        if let limitSeconds {
            deadline = ContinuousClock.now + .seconds(limitSeconds)
        } else {
            deadline = nil
        }
    }

    /// Returns true when workers must stop. Cheap enough to call once per directory.
    func check() -> Bool {
        if flag.load(ordering: .relaxed) { return true }
        if let deadline, ContinuousClock.now >= deadline {
            flag.store(true, ordering: .relaxed)
            return true
        }
        return false
    }

    var tripped: Bool { flag.load(ordering: .relaxed) }
}

/// Runs `body` on `workers` real threads (so `--workers n` means n concurrent threads) and merges results.
func runPool(workers: Int, body: @escaping @Sendable (Int) -> Counters) -> Counters {
    let results = OSAllocatedUnfairLock<[Counters]>(initialState: [])
    let group = DispatchGroup()
    for index in 0..<workers {
        group.enter()
        let thread = Thread {
            let counters = body(index)
            results.withLock { $0.append(counters) }
            group.leave()
        }
        thread.stackSize = 4 << 20
        thread.start()
    }
    group.wait()
    return results.withLock { all in
        var total = Counters()
        for item in all { total.merge(item) }
        return total
    }
}

/// Static job list for the fm and fts methods (top-level subdirectories).
final class JobList<Job: Sendable>: Sendable {
    private let jobs: OSAllocatedUnfairLock<[Job]>

    init(_ jobs: [Job]) { self.jobs = OSAllocatedUnfairLock(initialState: jobs) }

    func next() -> Job? { jobs.withLock { $0.popLast() } }
}

/// Peak resident set size in bytes (`ru_maxrss` is bytes on macOS).
func peakRSSBytes() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int(usage.ru_maxrss)
}

/// Raises the soft open-file limit so deep trees times many workers do not hit 256.
func raiseFileLimit() {
    var limit = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
    let wanted = rlim_t(10240)
    limit.rlim_cur = min(wanted, limit.rlim_max)
    setrlimit(RLIMIT_NOFILE, &limit)
}

/// Result line printed by the tool.
struct BenchResult: Codable {
    let method: String
    let workers: Int
    let root: String
    let files: Int
    let dirs: Int
    let symlinks: Int
    let hardlinkDupesSkipped: Int
    let permissionDenied: Int
    let otherErrors: Int
    let crossDeviceSkipped: Int
    let allocatedBytes: Int64
    let wallSeconds: Double
    let filesPerSecond: Double
    let peakRSSBytes: Int
    let partial: Bool

    var textLine: String {
        let secs = String(format: "%.3f", wallSeconds)
        let rate = String(format: "%.0f", filesPerSecond)
        return "method=\(method) workers=\(workers) root=\(root) files=\(files) dirs=\(dirs) "
            + "symlinks=\(symlinks) hardlinkDupesSkipped=\(hardlinkDupesSkipped) "
            + "permissionDenied=\(permissionDenied) otherErrors=\(otherErrors) "
            + "crossDeviceSkipped=\(crossDeviceSkipped) allocatedBytes=\(allocatedBytes) "
            + "wallSeconds=\(secs) filesPerSecond=\(rate) peakRSSBytes=\(peakRSSBytes) partial=\(partial)"
    }
}
