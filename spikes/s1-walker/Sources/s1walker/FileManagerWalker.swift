import Darwin
import Foundation

/// Opaque file identity from `fileResourceIdentifierKey`. Unique within one volume.
/// `@unchecked Sendable`: the wrapped NSObject is immutable and only used for hash/equality.
private struct FileKey: Hashable, @unchecked Sendable {
    let object: NSObject
}

private let fmKeyList: [URLResourceKey] = [
    .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
    .fileResourceIdentifierKey, .linkCountKey, .volumeIdentifierKey,
]
private let fmKeySet = Set(fmKeyList)

private struct FMContext: Sendable {
    let links: HardLinks<FileKey>
    let stop: StopControl
    let rootVolume: FileKey?
}

/// Counts errors the enumerator reports. Used from one thread only.
private final class ErrorBox {
    var counters = Counters()

    func record(_ error: any Error) {
        let ns = error as NSError
        if let posix = posixCode(of: ns) {
            counters.record(errno: posix)
        } else if ns.domain == NSCocoaErrorDomain
            && (ns.code == NSFileReadNoPermissionError || ns.code == NSFileWriteNoPermissionError)
        {
            counters.permissionDenied += 1
        } else {
            counters.otherErrors += 1
        }
    }
}

private func posixCode(of error: NSError) -> Int32? {
    if error.domain == NSPOSIXErrorDomain { return Int32(truncatingIfNeeded: error.code) }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
        return posixCode(of: underlying)
    }
    return nil
}

private enum FMKind {
    case directory
    case crossVolume
    case counted
}

/// Classifies one entry and counts it if it is not a directory.
private func fmHandle(_ values: URLResourceValues, counters: inout Counters, context: FMContext) -> FMKind {
    if values.isSymbolicLink != true && values.isDirectory == true {
        if let rootVolume = context.rootVolume {
            guard let volume = values.volumeIdentifier as? NSObject, volume.isEqual(rootVolume.object) else {
                counters.crossDeviceSkipped += 1
                return .crossVolume
            }
        }
        return .directory
    }
    if let linkCount = values.linkCount, linkCount > 1 {
        guard let identifier = values.fileResourceIdentifier as? NSObject else {
            counters.otherErrors += 1
            return .counted
        }
        if !context.links.firstSighting(FileKey(object: identifier)) {
            counters.hardlinkDupesSkipped += 1
            return .counted
        }
    }
    if values.isSymbolicLink == true {
        counters.symlinks += 1
    } else {
        counters.files += 1
    }
    // Foundation returns nil here for FIFOs and similar special files (bulk and fts report 0).
    // That is not a read failure, so it adds 0 without raising an error.
    if let allocated = values.totalFileAllocatedSize {
        counters.allocatedBytes += Int64(allocated)
    }
    return .counted
}

/// Walks `directory` completely (it counts itself as one directory).
private func fmWalk(_ directory: URL, counters: inout Counters, context: FMContext) {
    counters.dirs += 1
    let box = ErrorBox()
    guard
        let enumerator = FileManager().enumerator(
            at: directory, includingPropertiesForKeys: fmKeyList, options: [],
            errorHandler: { _, error in
                box.record(error)
                return true
            })
    else {
        counters.otherErrors += 1
        return
    }
    var ticks = 0
    var finished = false
    while !finished {
        ticks += 1
        if ticks & 255 == 0, context.stop.check() { break }
        // Each entry creates autoreleased Foundation objects; drain them per entry.
        autoreleasepool {
            guard let url = enumerator.nextObject() as? URL else {
                finished = true
                return
            }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: fmKeySet)
            } catch {
                box.record(error)
                return
            }
            switch fmHandle(values, counters: &counters, context: context) {
            case .directory: counters.dirs += 1
            case .crossVolume: enumerator.skipDescendants()
            case .counted: break
            }
        }
    }
    counters.merge(box.counters)
}

/// Lists the top level only. Files are counted; directories become jobs.
private func fmListTop(_ root: URL, counters: inout Counters, context: FMContext) -> [URL] {
    counters.dirs += 1
    var jobs: [URL] = []
    let box = ErrorBox()
    guard
        let enumerator = FileManager().enumerator(
            at: root, includingPropertiesForKeys: fmKeyList, options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                box.record(error)
                return true
            })
    else {
        counters.otherErrors += 1
        return jobs
    }
    var finished = false
    while !finished {
        autoreleasepool {
            guard let url = enumerator.nextObject() as? URL else {
                finished = true
                return
            }
            do {
                let values = try url.resourceValues(forKeys: fmKeySet)
                if fmHandle(values, counters: &counters, context: context) == .directory {
                    jobs.append(url)
                }
            } catch {
                box.record(error)
            }
        }
    }
    counters.merge(box.counters)
    return jobs
}

/// Runs the FileManager method. With more than one worker, top-level subdirectories are the jobs.
func runFileManager(root: String, workers: Int, stop: StopControl) -> Counters {
    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    guard let rootValues = try? rootURL.resourceValues(forKeys: [.volumeIdentifierKey]),
        let volume = rootValues.volumeIdentifier as? NSObject
    else {
        var failed = Counters()
        failed.otherErrors = 1
        return failed
    }
    let context = FMContext(links: HardLinks<FileKey>(), stop: stop, rootVolume: FileKey(object: volume))
    if workers <= 1 {
        var counters = Counters()
        fmWalk(rootURL, counters: &counters, context: context)
        return counters
    }
    var base = Counters()
    let jobs = JobList(fmListTop(rootURL, counters: &base, context: context))
    var total = runPool(workers: workers) { _ in
        var counters = Counters()
        while let job = jobs.next() {
            if context.stop.check() { break }
            fmWalk(job, counters: &counters, context: context)
        }
        return counters
    }
    total.merge(base)
    return total
}
