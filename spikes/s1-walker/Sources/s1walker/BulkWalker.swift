import Darwin
import Foundation

private let bulkBufferSize = 256 * 1024

// vnode types from <sys/vnode.h> (fsobj_type_t)
private let vnodeDirectory: UInt32 = 2
private let vnodeSymlink: UInt32 = 5

/// Queue of open directory fds shared by the bulk workers.
///
/// `pending` counts queued plus in-flight jobs, so a worker knows when the whole walk is over.
/// `@unchecked Sendable`: every access to the mutable state is under `cond`.
final class FDQueue: @unchecked Sendable {
    private let cond = NSCondition()
    private var items: [Int32] = []
    private var pending = 0
    private var stopped = false

    func push(_ fd: Int32) {
        cond.lock()
        items.append(fd)
        pending += 1
        cond.signal()
        cond.unlock()
    }

    /// Hands a directory to other workers only while fewer than `limit` wait. Bounds open fds.
    func pushIfBelow(_ fd: Int32, limit: Int) -> Bool {
        cond.lock()
        defer { cond.unlock() }
        guard items.count < limit, !stopped else { return false }
        items.append(fd)
        pending += 1
        cond.signal()
        return true
    }

    /// Blocks until a directory is available. Returns nil when the walk is finished or stopped.
    func pop() -> Int32? {
        cond.lock()
        defer { cond.unlock() }
        while true {
            if stopped { return nil }
            if let fd = items.popLast() { return fd }
            if pending == 0 { return nil }
            cond.wait()
        }
    }

    /// Marks one job (queued or in flight) as finished.
    func done() {
        cond.lock()
        pending -= 1
        if pending == 0 { cond.broadcast() }
        cond.unlock()
    }

    func stop() {
        cond.lock()
        stopped = true
        cond.broadcast()
        cond.unlock()
    }

    /// Takes whatever is still queued (after a stop) so the caller can close the fds.
    func drain() -> [Int32] {
        cond.lock()
        defer { cond.unlock() }
        let rest = items
        items.removeAll()
        return rest
    }
}

struct BulkContext: Sendable {
    let queue: FDQueue
    let links: HardLinks<LinkKey>
    let stop: StopControl
    let rootDevice: UInt32
    /// 0 disables hand-off (single worker).
    let handoffLimit: Int
}

/// A directory being walked depth-first. `names` holds its subdirectory names, NUL separated.
private struct Frame {
    var fd: Int32
    var names: [CChar] = []
    var cursor = 0

    var hasMore: Bool { cursor < names.count }

    /// Returns the offset of the next subdirectory name and advances.
    mutating func takeNext() -> Int {
        let start = cursor
        var end = start
        while end < names.count && names[end] != 0 { end += 1 }
        cursor = end + 1
        return start
    }
}

/// Bounds-checked reader over one packed `getattrlistbulk` entry.
private struct EntryReader {
    let base: UnsafeRawPointer
    let length: Int
    var offset: Int

    mutating func take<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= length else { return nil }
        let value = base.loadUnaligned(fromByteOffset: offset, as: T.self)
        offset += size
        return value
    }
}

private func makeAttrList() -> attrlist {
    var list = attrlist()
    list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        | attrgroup_t(ATTR_CMN_ERROR)
        | attrgroup_t(ATTR_CMN_NAME)
        | attrgroup_t(ATTR_CMN_DEVID)
        | attrgroup_t(ATTR_CMN_OBJTYPE)
        | attrgroup_t(ATTR_CMN_FILEID)
        | attrgroup_t(ATTR_CMN_FLAGS)
    list.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
    return list
}

/// Worker body: pull directories off the shared queue until the walk ends.
func bulkWorker(context: BulkContext) -> Counters {
    var counters = Counters()
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: bulkBufferSize, alignment: 16)
    defer { buffer.deallocate() }
    while let fd = context.queue.pop() {
        bulkWalk(rootFD: fd, counters: &counters, buffer: buffer, context: context)
        context.queue.done()
    }
    return counters
}

/// Depth-first walk from `rootFD` (takes ownership of it and every fd it opens).
private func bulkWalk(
    rootFD: Int32, counters: inout Counters, buffer: UnsafeMutableRawPointer, context: BulkContext
) {
    var stack: [Frame] = [readDirectory(fd: rootFD, counters: &counters, buffer: buffer, context: context)]
    while !stack.isEmpty {
        if context.stop.check() {
            context.queue.stop()
            for frame in stack where frame.fd >= 0 { close(frame.fd) }
            return
        }
        let top = stack.count - 1
        guard stack[top].hasMore else {
            if stack[top].fd >= 0 { close(stack[top].fd) }
            stack.removeLast()
            continue
        }
        let offset = stack[top].takeNext()
        let parentFD = stack[top].fd
        let child = stack[top].names.withUnsafeBufferPointer { pointer -> Int32 in
            guard let start = pointer.baseAddress else { return -1 }
            return openat(parentFD, start + offset, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        // The last child is out; the parent fd is no longer needed.
        if !stack[top].hasMore {
            close(stack[top].fd)
            stack[top].fd = -1
        }
        if child < 0 {
            counters.record(errno: errno)
            continue
        }
        // A mount point reports the covered directory's device in the parent's listing,
        // so confirm on the opened descriptor too.
        var info = stat()
        guard fstat(child, &info) == 0 else {
            counters.otherErrors += 1
            close(child)
            continue
        }
        if UInt32(bitPattern: info.st_dev) != context.rootDevice {
            counters.dirs -= 1
            counters.crossDeviceSkipped += 1
            close(child)
            continue
        }
        if context.handoffLimit > 0, context.queue.pushIfBelow(child, limit: context.handoffLimit) {
            continue
        }
        stack.append(readDirectory(fd: child, counters: &counters, buffer: buffer, context: context))
    }
}

/// Reads one directory with `getattrlistbulk`, counts its entries, and collects subdirectory names.
private func readDirectory(
    fd: Int32, counters: inout Counters, buffer: UnsafeMutableRawPointer, context: BulkContext
) -> Frame {
    var frame = Frame(fd: fd)
    var list = makeAttrList()
    while true {
        let count = getattrlistbulk(fd, &list, buffer, bulkBufferSize, 0)
        if count < 0 {
            if errno == EINTR { continue }
            counters.record(errno: errno)
            break
        }
        if count == 0 { break }
        var entryStart = 0
        for _ in 0..<Int(count) {
            guard entryStart + 4 <= bulkBufferSize else {
                counters.otherErrors += 1
                break
            }
            let length = Int(buffer.loadUnaligned(fromByteOffset: entryStart, as: UInt32.self))
            // 4 (length) + 20 (returned attrs) is the smallest valid entry.
            guard length >= 24, entryStart + length <= bulkBufferSize else {
                counters.otherErrors += 1
                break
            }
            let entry = UnsafeRawPointer(buffer + entryStart)
            parseEntry(entry, length: length, frame: &frame, counters: &counters, context: context)
            entryStart += length
        }
    }
    return frame
}

/// Parses one packed entry. Layout (attributes appear in bit order, 4-byte packed):
/// length, returned attrs (5 x u32), [error], name ref, devid, objtype, flags, fileid,
/// then file attrs: linkcount, allocsize.
private func parseEntry(
    _ entry: UnsafeRawPointer, length: Int, frame: inout Frame,
    counters: inout Counters, context: BulkContext
) {
    var reader = EntryReader(base: entry, length: length, offset: 4)
    guard let common = reader.take(UInt32.self),
        reader.take(UInt32.self) != nil,  // volattr
        reader.take(UInt32.self) != nil,  // dirattr
        let file = reader.take(UInt32.self),
        reader.take(UInt32.self) != nil  // forkattr
    else {
        counters.otherErrors += 1
        return
    }
    if common & attrgroup_t(ATTR_CMN_ERROR) != 0 {
        if let code = reader.take(UInt32.self) {
            counters.record(errno: Int32(truncatingIfNeeded: code))
        } else {
            counters.otherErrors += 1
        }
        return
    }
    guard common & attrgroup_t(ATTR_CMN_NAME) != 0,
        common & attrgroup_t(ATTR_CMN_DEVID) != 0,
        common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0
    else {
        counters.otherErrors += 1
        return
    }
    let nameFieldOffset = reader.offset
    guard let nameOffset = reader.take(Int32.self), let nameLength = reader.take(UInt32.self),
        let device = reader.take(UInt32.self), let objectType = reader.take(UInt32.self)
    else {
        counters.otherErrors += 1
        return
    }
    if common & attrgroup_t(ATTR_CMN_FLAGS) != 0, reader.take(UInt32.self) == nil {
        counters.otherErrors += 1
        return
    }
    var fileID: UInt64?
    if common & attrgroup_t(ATTR_CMN_FILEID) != 0 {
        fileID = reader.take(UInt64.self)
        if fileID == nil {
            counters.otherErrors += 1
            return
        }
    }
    var linkCount: UInt32?
    if file & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 { linkCount = reader.take(UInt32.self) }
    var allocated: Int64?
    if file & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 { allocated = reader.take(Int64.self) }

    if device != context.rootDevice {
        counters.crossDeviceSkipped += 1
        return
    }

    if objectType == vnodeDirectory {
        let nameStart = nameFieldOffset + Int(nameOffset)
        let nameBytes = Int(nameLength)
        guard nameBytes >= 2, nameStart >= 0, nameStart + nameBytes <= length else {
            counters.otherErrors += 1
            return
        }
        counters.dirs += 1
        let raw = entry.advanced(by: nameStart)
        for index in 0..<(nameBytes - 1) {
            frame.names.append(CChar(bitPattern: raw.load(fromByteOffset: index, as: UInt8.self)))
        }
        frame.names.append(0)
        return
    }

    if let linkCount, linkCount > 1 {
        guard let fileID else {
            counters.otherErrors += 1
            return
        }
        if !context.links.firstSighting(LinkKey(device: device, fileID: fileID)) {
            counters.hardlinkDupesSkipped += 1
            return
        }
    }
    if objectType == vnodeSymlink {
        counters.symlinks += 1
    } else {
        counters.files += 1
    }
    if let allocated {
        counters.allocatedBytes += allocated
    } else {
        counters.otherErrors += 1
    }
}

/// Runs the bulk method over `root`. The root directory itself counts as one directory.
func runBulk(root: String, workers: Int, stop: StopControl) -> Counters {
    let rootFD = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    var base = Counters()
    base.dirs = 1
    guard rootFD >= 0 else {
        base.record(errno: errno)
        return base
    }
    var info = stat()
    guard fstat(rootFD, &info) == 0 else {
        base.otherErrors += 1
        close(rootFD)
        return base
    }
    let queue = FDQueue()
    queue.push(rootFD)
    let context = BulkContext(
        queue: queue, links: HardLinks<LinkKey>(), stop: stop,
        rootDevice: UInt32(bitPattern: info.st_dev),
        handoffLimit: workers > 1 ? workers : 0)
    var total = runPool(workers: workers) { _ in bulkWorker(context: context) }
    for fd in queue.drain() { close(fd) }
    total.merge(base)
    return total
}
