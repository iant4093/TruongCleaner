import Darwin
import Foundation

private let bulkBufferSize = 256 * 1024

// vnode types from <sys/vnode.h> (fsobj_type_t)
private let vnodeRegular: UInt32 = 1
private let vnodeDirectory: UInt32 = 2
private let vnodeSymlink: UInt32 = 5

// ATTR_DIR_MOUNTSTATUS bits from <sys/attr.h>.
private let directoryIsMountPoint: UInt32 = 0x0000_0001  // DIR_MNTSTATUS_MNTPOINT
private let directoryIsAutomountTrigger: UInt32 = 0x0000_0002  // DIR_MNTSTATUS_TRIGGER

/// Counts kept per worker and merged at the end.
struct WalkCounters: Sendable {
    var files = 0
    var directories = 0
    var symlinks = 0
    var hardLinkDuplicates = 0
    var crossVolumeSkipped = 0
    var otherErrors = 0
    var privateSizeMissing = 0
    /// Allocated bytes counted by this worker (used for progress).
    var allocatedBytes: Int64 = 0

    mutating func merge(_ other: WalkCounters) {
        files += other.files
        directories += other.directories
        symlinks += other.symlinks
        hardLinkDuplicates += other.hardLinkDuplicates
        crossVolumeSkipped += other.crossVolumeSkipped
        otherErrors += other.otherErrors
        privateSizeMissing += other.privateSizeMissing
        allocatedBytes += other.allocatedBytes
    }
}

/// What one worker hands back when it ends.
struct WorkerOutput: Sendable {
    var counters: WalkCounters
    var top: TopFiles
}

/// Everything the workers share. All members are safe to use from several threads.
struct WalkContext: Sendable {
    let queue: JobQueue
    let links: HardLinkSet
    let nodes: SizeAccumulator
    let denied: DeniedList
    let stop: StopControl
    let progress: ProgressReporter
    /// `ATTR_CMN_FSID` of the root. Only a fast pre-filter for listed entries: System and Data share one value.
    let rootFSID: UInt64
    /// `f_fsid` of the root's file system (`volumeIdentity(of:)`). The real volume boundary.
    let rootVolume: UInt64
    let totalsDepth: Int
    let topFilesCapacity: Int
    /// 0 disables hand-off (single worker).
    let handoffLimit: Int
    /// Folder names whose subtree is totaled as one node.
    let prune: PrunePlan
    /// Which folders of a `.glob` rule are opened at all. nil opens everything.
    let descent: DescentFilter?
    /// Where a worker asks for more threads. nil when the walk has a fixed set of threads.
    let extras: ExtraWorkers?
}

/// A directory being walked depth-first. `names` holds its subdirectory names, NUL terminated.
private struct Frame {
    var fd: Int32
    let path: [CChar]
    let depth: Int
    let keptNode: Int
    let prune: PruneState
    let descent: DescentCursor
    var totals = Totals()
    var names: [CChar] = []
    var directories: [PendingDirectory] = []
    var cursor = 0

    var hasMore: Bool { cursor < directories.count }
}

/// A subdirectory seen in a listing, waiting to be opened.
private struct PendingDirectory {
    var nameOffset: Int
    var id: EntryID
    var flags: UInt32
    var modified: Int64
}

/// Bounds-checked reader over one packed `getattrlistbulk` entry.
struct EntryReader {
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

private func makeAttributeList() -> attrlist {
    var list = attrlist()
    list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        | attrgroup_t(ATTR_CMN_ERROR)
        | attrgroup_t(ATTR_CMN_NAME)
        | attrgroup_t(ATTR_CMN_FSID)
        | attrgroup_t(ATTR_CMN_OBJTYPE)
        | attrgroup_t(ATTR_CMN_MODTIME)
        | attrgroup_t(ATTR_CMN_FLAGS)
        | attrgroup_t(ATTR_CMN_FILEID)
    // A mount point lists with its parent's fsid and opening it can block (stale share, autofs trigger),
    // so ask for the mount status and skip such folders before opening them.
    list.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
    list.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
    // With FSOPT_ATTR_CMN_EXTENDED the fork field selects the ATTR_CMNEXT_* attributes.
    list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
    return list
}

/// Packs an `fsid_t` into one number: `val[0] << 32 | val[1]`.
func packFSID(_ first: Int32, _ second: Int32) -> UInt64 {
    UInt64(UInt32(bitPattern: first)) << 32 | UInt64(UInt32(bitPattern: second))
}

/// The `ATTR_CMN_FSID` of an open descriptor, packed. This is the value `getattrlistbulk` lists for every
/// entry and the one `Finding.fsid` carries (the safety gate re-reads it the same way).
///
/// It does not tell the System volume from the Data volume: both report the same value. Use
/// ``volumeIdentity(of:)`` for the volume boundary.
func attributeFSID(of fd: Int32) -> UInt64? {
    var list = attrlist()
    list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    list.commonattr = attrgroup_t(ATTR_CMN_FSID)
    var reply: (length: UInt32, first: Int32, second: Int32) = (0, 0, 0)
    let result = withUnsafeMutableBytes(of: &reply) { bytes in
        fgetattrlist(fd, &list, bytes.baseAddress, bytes.count, 0)
    }
    guard result == 0, reply.length >= 12 else { return nil }
    return packFSID(reply.first, reply.second)
}

/// The identity of the file system an open descriptor lives on, from `fstatfs(2)`'s `f_fsid`, packed like
/// ``packFSID(_:_:)``. Unlike `ATTR_CMN_FSID` it differs between the System volume and the Data volume,
/// so it is what decides whether a walk may enter a folder (REQ-SCAN-03).
func volumeIdentity(of fd: Int32) -> UInt64? {
    var info = statfs()
    guard fstatfs(fd, &info) == 0 else { return nil }
    return packFSID(info.f_fsid.val.0, info.f_fsid.val.1)
}

/// Copies `parent`, adds `/`, then the NUL-terminated name. `parent` ends with NUL; so does the result.
private func appendComponent(to parent: [CChar], name: UnsafePointer<CChar>, maxLength: Int) -> [CChar] {
    let nameLength = strnlen(name, maxLength)
    var result: [CChar] = []
    result.reserveCapacity(parent.count + nameLength + 2)
    result.append(contentsOf: parent.dropLast())
    if result.last != CChar(UInt8(ascii: "/")) { result.append(CChar(UInt8(ascii: "/"))) }
    result.append(contentsOf: UnsafeBufferPointer(start: name, count: nameLength))
    result.append(0)
    return result
}

/// One worker thread's state. Reuses a single buffer for every `getattrlistbulk` call.
struct DirectoryWalker {
    private let context: WalkContext
    private let buffer: UnsafeMutableRawPointer
    private let attributes = makeAttributeList()
    private var counters = WalkCounters()
    private var top: TopFiles

    private init(context: WalkContext, buffer: UnsafeMutableRawPointer) {
        self.context = context
        self.buffer = buffer
        self.top = TopFiles(capacity: context.topFilesCapacity)
    }

    /// Worker body: take directories off the shared queue until the walk ends.
    static func work(context: WalkContext) -> WorkerOutput {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bulkBufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var walker = DirectoryWalker(context: context, buffer: buffer)
        while let job = context.queue.pop() {
            walker.walk(job)
            context.queue.done()
        }
        return WorkerOutput(counters: walker.counters, top: walker.top)
    }

    // MARK: Walking

    /// Depth-first walk from `job` (takes ownership of its descriptor and of every descriptor it opens).
    private mutating func walk(_ job: WalkJob) {
        var stack = [
            Frame(
                fd: job.fd, path: job.path, depth: job.depth, keptNode: job.keptNode, prune: job.prune,
                descent: job.descent)
        ]
        readDirectory(&stack[0])
        while !stack.isEmpty {
            if context.stop.check() {
                if stack.contains(where: { $0.hasMore }) { context.stop.markIncomplete() }
                for frame in stack { finish(frame) }
                context.queue.stop()
                return
            }
            let last = stack.count - 1
            guard stack[last].hasMore else {
                finish(stack[last])
                stack.removeLast()
                continue
            }
            if let child = enterNextDirectory(of: &stack[last]) {
                stack.append(child)
            }
        }
    }

    /// Closes the frame's descriptor and flushes its totals into the kept node.
    private func finish(_ frame: Frame) {
        if frame.fd >= 0 { close(frame.fd) }
        context.nodes.add(frame.totals, to: frame.keptNode)
    }

    /// Opens the parent's next subdirectory. Returns a frame to walk, or nil when the directory
    /// was handed to another worker, skipped, or could not be opened.
    private mutating func enterNextDirectory(of parent: inout Frame) -> Frame? {
        let pending = parent.directories[parent.cursor]
        parent.cursor += 1
        let parentFD = parent.fd
        // A folder that cannot hold or be a match of the rule's glob is not opened (see `DescentFilter`).
        var childDescent = DescentCursor.everything
        if let filter = context.descent {
            let decision = parent.names.withUnsafeBufferPointer { names -> DescentCursor? in
                guard let base = names.baseAddress else { return .everything }
                return filter.enter(base + pending.nameOffset, from: parent.descent, depth: parent.depth)
            }
            guard let cursor = decision else {
                if !parent.hasMore {
                    close(parent.fd)
                    parent.fd = -1
                }
                // Its own date still counts towards the folder above, as for any folder.
                parent.totals.note(time: pending.modified)
                return nil
            }
            childDescent = cursor
        }
        let childFD = parent.names.withUnsafeBufferPointer { names -> Int32 in
            guard let base = names.baseAddress else { return -1 }
            return openat(parentFD, base + pending.nameOffset, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        let openError = childFD < 0 ? errno : 0
        // The last child is out; the parent descriptor is no longer needed.
        if !parent.hasMore {
            close(parent.fd)
            parent.fd = -1
        }
        let parentPrune = parent.prune
        let (childPrune, keepsNode) = parent.names.withUnsafeBufferPointer { names -> (PruneState, Bool) in
            guard let base = names.baseAddress else { return (parentPrune == .none ? .none : .inside, true) }
            let name = base + pending.nameOffset
            return (
                context.prune.state(ofChildNamed: name, parent: parentPrune),
                context.prune.keepsNode(childNamed: name, parent: parentPrune)
            )
        }
        let path = parent.names.withUnsafeBufferPointer { names -> [CChar] in
            guard let base = names.baseAddress else { return parent.path }
            return appendComponent(to: parent.path, name: base + pending.nameOffset, maxLength: names.count - pending.nameOffset)
        }

        if childFD < 0 {
            if openError == EPERM || openError == EACCES {
                // The folder exists but is closed to us: its size is unknown, not zero.
                context.denied.record { makeURL(fromPath: path, isDirectory: true) }
                _ = register(pending, path: path, parent: &parent, keepsNode: keepsNode)
            } else {
                counters.otherErrors += 1
            }
            return nil
        }
        // Backstop for the mount status in the listing: the volume of the opened folder must be the root's.
        // `f_fsid`, not `ATTR_CMN_FSID`, because the latter is the same on System and Data.
        guard let volume = volumeIdentity(of: childFD) else {
            counters.otherErrors += 1
            close(childFD)
            return nil
        }
        if volume != context.rootVolume {
            counters.crossVolumeSkipped += 1
            close(childFD)
            return nil
        }
        let keptNode = register(pending, path: path, parent: &parent, keepsNode: keepsNode)
        let job = WalkJob(
            fd: childFD, path: path, depth: parent.depth + 1, keptNode: keptNode, prune: childPrune,
            descent: childDescent)
        if context.handoffLimit > 0 {
            let handedOff = context.queue.pushIfBelow(job, limit: context.handoffLimit)
            // Work is waiting (just queued, or the queue is already full): let the walk take a free
            // thread from the scan's budget, if there is one now. A full queue is asked again for every
            // folder, so a thread that frees up later is used.
            context.extras?.offer()
            if handedOff { return nil }
        }
        var frame = Frame(
            fd: job.fd, path: job.path, depth: job.depth, keptNode: job.keptNode, prune: job.prune,
            descent: job.descent)
        readDirectory(&frame)
        return frame
    }

    /// Counts a folder and, within `totalsDepth`, gives it a node. Returns the node that receives its totals.
    /// A folder inside a pruned folder (`keepsNode == false`) has no node: its totals go to `parent.keptNode`.
    private mutating func register(
        _ pending: PendingDirectory, path: [CChar], parent: inout Frame, keepsNode: Bool
    ) -> Int {
        counters.directories += 1
        let depth = parent.depth + 1
        guard keepsNode, depth <= context.totalsDepth else {
            parent.totals.note(time: pending.modified)
            return parent.keptNode
        }
        var own = Totals()
        own.note(time: pending.modified)
        let record = NodeRecord(
            url: makeURL(fromPath: path, isDirectory: true), depth: depth, id: pending.id,
            kind: .directory, flags: pending.flags, parent: parent.keptNode)
        return context.nodes.addNode(record, initial: own)
    }

    // MARK: Reading one directory

    /// Reads one directory with `getattrlistbulk`, counts its files, and collects subdirectory names.
    private mutating func readDirectory(_ frame: inout Frame) {
        context.progress.tick(path: frame.path)
        let filesBefore = counters.files
        let bytesBefore = counters.allocatedBytes
        var list = attributes
        while true {
            // One check per batch keeps cancellation fast even inside huge folders.
            if context.stop.check() {
                context.stop.markIncomplete()
                break
            }
            let count = getattrlistbulk(frame.fd, &list, buffer, bulkBufferSize, UInt64(FSOPT_ATTR_CMN_EXTENDED))
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                if code == EPERM || code == EACCES {
                    context.denied.record { makeURL(fromPath: frame.path, isDirectory: true) }
                } else {
                    counters.otherErrors += 1
                }
                break
            }
            if count == 0 { break }
            var entryStart = 0
            for index in 0..<Int(count) {
                // A 1,000-entry batch can take ~70 ms (more under load); check for stop every
                // 64 entries so cancellation lands within budget (EVIDENCE, task 2.6b).
                // The outer loop's stop check then marks the walk incomplete.
                if index & 63 == 63, context.stop.check() { break }
                guard entryStart + 4 <= bulkBufferSize else {
                    counters.otherErrors += 1
                    break
                }
                let length = Int(buffer.loadUnaligned(fromByteOffset: entryStart, as: UInt32.self))
                // 4 (length) + 20 (returned attributes) is the smallest valid entry.
                guard length >= 24, entryStart + length <= bulkBufferSize else {
                    counters.otherErrors += 1
                    break
                }
                parse(entry: UnsafeRawPointer(buffer + entryStart), length: length, frame: &frame)
                entryStart += length
            }
        }
        context.progress.add(files: counters.files - filesBefore, bytes: counters.allocatedBytes - bytesBefore)
    }

    /// Parses one packed entry. Layout (4-byte packed, each group in bit order):
    /// length, returned attributes (5 words), [error], name reference, fsid (2 words), object type,
    /// modification time (2 x 64 bit), flags, file ID, link count, allocated size, private size.
    private mutating func parse(entry: UnsafeRawPointer, length: Int, frame: inout Frame) {
        var reader = EntryReader(base: entry, length: length, offset: 4)
        guard let common = reader.take(UInt32.self),
            reader.take(UInt32.self) != nil,  // volume attributes
            let directory = reader.take(UInt32.self),
            let file = reader.take(UInt32.self),
            let fork = reader.take(UInt32.self)
        else {
            counters.otherErrors += 1
            return
        }
        if common & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            parseFailedEntry(&reader, common: common, entry: entry, length: length, frame: frame)
            return
        }
        guard common & attrgroup_t(ATTR_CMN_NAME) != 0,
            common & attrgroup_t(ATTR_CMN_FSID) != 0,
            common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0,
            common & attrgroup_t(ATTR_CMN_FILEID) != 0
        else {
            counters.otherErrors += 1
            return
        }
        let nameFieldOffset = reader.offset
        guard let nameOffset = reader.take(Int32.self), let nameLength = reader.take(UInt32.self),
            let fsidFirst = reader.take(Int32.self), let fsidSecond = reader.take(Int32.self),
            let objectType = reader.take(UInt32.self)
        else {
            counters.otherErrors += 1
            return
        }
        var modified = Int64.min
        if common & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
            guard let seconds = reader.take(Int64.self), let nanos = reader.take(Int64.self) else {
                counters.otherErrors += 1
                return
            }
            modified = packTime(seconds: seconds, nanoseconds: nanos)
        }
        var flags: UInt32 = 0
        if common & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
            guard let value = reader.take(UInt32.self) else {
                counters.otherErrors += 1
                return
            }
            flags = value
        }
        guard let fileID = reader.take(UInt64.self) else {
            counters.otherErrors += 1
            return
        }
        var mountStatus: UInt32 = 0
        if directory & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
            guard let value = reader.take(UInt32.self) else {
                counters.otherErrors += 1
                return
            }
            mountStatus = value
        }
        var linkCount: UInt32?
        if file & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 { linkCount = reader.take(UInt32.self) }
        var allocated: Int64?
        if file & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 { allocated = reader.take(Int64.self) }
        var privateSize: Int64?
        if fork & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 { privateSize = reader.take(Int64.self) }

        let id = EntryID(fsid: packFSID(fsidFirst, fsidSecond), fileID: fileID)
        if id.fsid != context.rootFSID {
            counters.crossVolumeSkipped += 1
            return
        }
        let nameStart = nameFieldOffset + Int(nameOffset)
        let nameBytes = Int(nameLength)
        guard nameBytes >= 2, nameStart >= 0, nameStart + nameBytes <= length else {
            counters.otherErrors += 1
            return
        }
        let name = entry.advanced(by: nameStart).assumingMemoryBound(to: CChar.self)

        if objectType == vnodeDirectory {
            if mountStatus & (directoryIsMountPoint | directoryIsAutomountTrigger) != 0 {
                // Never opened: a stale network mount or an autofs trigger can block the open for good.
                counters.crossVolumeSkipped += 1
                return
            }
            frame.directories.append(
                PendingDirectory(nameOffset: frame.names.count, id: id, flags: flags, modified: modified))
            frame.names.append(contentsOf: UnsafeBufferPointer(start: name, count: strnlen(name, nameBytes)))
            frame.names.append(0)
            return
        }
        record(
            nonDirectory: objectType, id: id, flags: flags, modified: modified, linkCount: linkCount,
            allocated: allocated, privateSize: privateSize, name: name, nameBytes: nameBytes, frame: &frame)
    }

    /// Counts a file, symlink or other non-folder entry.
    private mutating func record(
        nonDirectory objectType: UInt32, id: EntryID, flags: UInt32, modified: Int64, linkCount: UInt32?,
        allocated: Int64?, privateSize: Int64?, name: UnsafePointer<CChar>, nameBytes: Int, frame: inout Frame
    ) {
        let isSymlink = objectType == vnodeSymlink
        let isRegular = objectType == vnodeRegular
        var own = Totals()
        own.note(time: modified)

        var counted = true
        if !isSymlink, let linkCount, linkCount > 1, !context.links.firstSighting(id) {
            // Same file under another name: its bytes are already in the totals.
            counted = false
            counters.hardLinkDuplicates += 1
        }
        if isSymlink {
            counters.symlinks += 1
        } else if counted {
            counters.files += 1
            own.files = 1
            if let allocated {
                own.allocated = max(0, allocated)
            } else if isRegular {
                counters.otherErrors += 1
            }
            if let privateSize {
                own.privateBytes = max(0, privateSize)
            } else {
                own.privateBytes = own.allocated
                if isRegular { counters.privateSizeMissing += 1 }
            }
            counters.allocatedBytes += own.allocated
        }

        let depth = frame.depth + 1
        let keepsNode = depth <= context.totalsDepth
            && context.prune.keepsNode(childNamed: name, parent: frame.prune)
        let entersTop = isRegular && counted && top.wouldAccept(allocated: own.allocated, fileID: id.fileID)
        guard keepsNode || entersTop else {
            frame.totals.merge(own)
            return
        }
        let path = appendComponent(to: frame.path, name: name, maxLength: nameBytes)
        let url = makeURL(fromPath: path, isDirectory: false)
        let kind: NodeTotal.Kind = isSymlink ? .symlink : (isRegular ? .file : .other)
        if entersTop {
            top.insert(
                NodeTotal(
                    url: url, depth: depth, id: id, kind: kind, flags: flags,
                    allocatedBytes: own.allocated, privateBytes: own.privateBytes, fileCount: 1,
                    newestModification: packedTimeToDate(modified)))
        }
        if keepsNode {
            // A kept file carries its own totals; the folder above gets them when the tree is rolled up.
            _ = context.nodes.addNode(
                NodeRecord(url: url, depth: depth, id: id, kind: kind, flags: flags, parent: frame.keptNode),
                initial: own)
        } else {
            frame.totals.merge(own)
        }
    }

    /// An entry that came back with `ATTR_CMN_ERROR`. Permission errors are reported as denied, never as size 0.
    private mutating func parseFailedEntry(
        _ reader: inout EntryReader, common: UInt32, entry: UnsafeRawPointer, length: Int, frame: Frame
    ) {
        guard let failed = FailedEntry.read(&reader, common: common, entry: entry, length: length) else {
            // Without a name there is no path to report; count it so it is not lost.
            counters.otherErrors += 1
            return
        }
        guard failed.code == EPERM || failed.code == EACCES else {
            counters.otherErrors += 1
            return
        }
        let path = appendComponent(to: frame.path, name: failed.name, maxLength: failed.nameBytes)
        let isDirectory = failed.isDirectory
        context.denied.record { makeURL(fromPath: path, isDirectory: isDirectory) }
    }
}

/// What an entry with `ATTR_CMN_ERROR` tells us: the error, the name and, when macOS says so, the kind.
struct FailedEntry {
    var code: Int32
    var name: UnsafePointer<CChar>
    var nameBytes: Int
    /// True only when `ATTR_CMN_OBJTYPE` came back and says folder. An unknown kind counts as a file, so
    /// the reported path never gets a trailing slash for something that may not be a folder.
    var isDirectory: Bool

    /// Reads the fields after the returned-attributes block. Layout: error, name reference, then
    /// (when returned) fsid and object type. Nil when the entry has no readable name.
    static func read(
        _ reader: inout EntryReader, common: UInt32, entry: UnsafeRawPointer, length: Int
    ) -> FailedEntry? {
        guard common & attrgroup_t(ATTR_CMN_ERROR) != 0, let code = reader.take(UInt32.self) else { return nil }
        let nameFieldOffset = reader.offset
        guard common & attrgroup_t(ATTR_CMN_NAME) != 0,
            let nameOffset = reader.take(Int32.self), let nameLength = reader.take(UInt32.self),
            case let nameStart = nameFieldOffset + Int(nameOffset), nameLength >= 2,
            nameStart >= 0, nameStart + Int(nameLength) <= length
        else { return nil }
        var isDirectory = false
        var fieldsOK = true
        if common & attrgroup_t(ATTR_CMN_FSID) != 0 {
            fieldsOK = reader.take(Int32.self) != nil && reader.take(Int32.self) != nil
        }
        if fieldsOK, common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0, let type = reader.take(UInt32.self) {
            isDirectory = type == vnodeDirectory
        }
        let name = entry.advanced(by: nameStart).assumingMemoryBound(to: CChar.self)
        return FailedEntry(
            code: Int32(truncatingIfNeeded: code), name: name, nameBytes: Int(nameLength), isDirectory: isDirectory)
    }
}
