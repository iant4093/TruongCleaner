import Darwin
import Foundation

/// Walks `path` with fts. When `splitTop` is true, level-1 directories are not entered;
/// their paths are returned as jobs instead. A walked root counts itself as one directory.
private func ftsWalk(
    path: String, rootDevice: dev_t, splitTop: Bool, counters: inout Counters,
    links: HardLinks<LinkKey>, stop: StopControl
) -> [String] {
    var jobs: [String] = []
    guard let cPath = strdup(path) else {
        counters.otherErrors += 1
        return jobs
    }
    defer { free(cPath) }
    var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
    guard let handle = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else {
        counters.record(errno: errno)
        return jobs
    }
    defer { fts_close(handle) }

    var ticks = 0
    while let entry = fts_read(handle) {
        ticks += 1
        if ticks & 255 == 0, stop.check() { break }
        let info = Int32(entry.pointee.fts_info)
        let level = Int(entry.pointee.fts_level)
        switch info {
        case FTS_D:
            guard let status = entry.pointee.fts_statp else {
                counters.otherErrors += 1
                continue
            }
            if status.pointee.st_dev != rootDevice {
                counters.crossDeviceSkipped += 1
                fts_set(handle, entry, FTS_SKIP)
                continue
            }
            if splitTop && level == 1 {
                jobs.append(String(cString: entry.pointee.fts_path))
                fts_set(handle, entry, FTS_SKIP)
                continue
            }
            counters.dirs += 1
        case FTS_DP:
            break
        case FTS_DNR:
            // macOS fts returns the directory first as FTS_D (already counted), then again
            // as FTS_DNR when it fails to read it. Count only the error here.
            counters.record(errno: entry.pointee.fts_errno)
        case FTS_ERR, FTS_NS, FTS_NSOK, FTS_DC:
            counters.record(errno: entry.pointee.fts_errno)
        case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
            guard let status = entry.pointee.fts_statp else {
                counters.otherErrors += 1
                continue
            }
            if status.pointee.st_nlink > 1,
                !links.firstSighting(LinkKey(device: UInt32(bitPattern: status.pointee.st_dev), fileID: status.pointee.st_ino))
            {
                counters.hardlinkDupesSkipped += 1
                continue
            }
            if info == FTS_SL || info == FTS_SLNONE {
                counters.symlinks += 1
            } else {
                counters.files += 1
            }
            counters.allocatedBytes += Int64(status.pointee.st_blocks) * 512
        default:
            counters.otherErrors += 1
        }
    }
    return jobs
}

/// Runs the fts method. With more than one worker, top-level subdirectories are the jobs.
func runFts(root: String, workers: Int, stop: StopControl) -> Counters {
    var rootInfo = stat()
    guard lstat(root, &rootInfo) == 0 else {
        var failed = Counters()
        failed.record(errno: errno)
        return failed
    }
    let rootDevice = rootInfo.st_dev
    let links = HardLinks<LinkKey>()
    var base = Counters()
    if workers <= 1 {
        _ = ftsWalk(path: root, rootDevice: rootDevice, splitTop: false, counters: &base, links: links, stop: stop)
        return base
    }
    let jobs = JobList(
        ftsWalk(path: root, rootDevice: rootDevice, splitTop: true, counters: &base, links: links, stop: stop))
    var total = runPool(workers: workers) { _ in
        var counters = Counters()
        while let job = jobs.next() {
            if stop.check() { break }
            _ = ftsWalk(path: job, rootDevice: rootDevice, splitTop: false, counters: &counters, links: links, stop: stop)
        }
        return counters
    }
    total.merge(base)
    return total
}
