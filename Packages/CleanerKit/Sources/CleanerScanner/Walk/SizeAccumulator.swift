import Foundation
import os

/// Running totals for one entry or one directory being read. A small value; nothing is kept per file.
struct Totals: Sendable {
    var allocated: Int64 = 0
    var privateBytes: Int64 = 0
    var files = 0
    /// Newest modification time as nanoseconds since 1970, or `Int64.min` when none was seen.
    var newest: Int64 = .min

    var isEmpty: Bool { allocated == 0 && privateBytes == 0 && files == 0 && newest == .min }

    mutating func note(time: Int64) {
        if time > newest { newest = time }
    }

    mutating func merge(_ other: Totals) {
        allocated += other.allocated
        privateBytes += other.privateBytes
        files += other.files
        note(time: other.newest)
    }
}

/// Packs a `timespec` into nanoseconds since 1970. Dates outside about 1678...2262 are dropped (`Int64.min`).
func packTime(seconds: Int64, nanoseconds: Int64) -> Int64 {
    guard seconds > -9_000_000_000, seconds < 9_000_000_000 else { return .min }
    return seconds * 1_000_000_000 + max(0, min(nanoseconds, 999_999_999))
}

/// Converts packed nanoseconds back to a date. `Int64.min` means "no date".
func packedTimeToDate(_ time: Int64) -> Date? {
    guard time != .min else { return nil }
    var seconds = time / 1_000_000_000
    var rest = time % 1_000_000_000
    if rest < 0 {
        seconds -= 1
        rest += 1_000_000_000
    }
    return Date(timeIntervalSince1970: Double(seconds) + Double(rest) / 1_000_000_000)
}

/// What a kept node is, fixed when it is created.
struct NodeRecord: Sendable {
    let url: URL
    let depth: Int
    let id: EntryID
    let kind: NodeTotal.Kind
    let flags: UInt32
    /// Index of the kept parent; the root points at itself.
    let parent: Int
}

/// Collects totals for kept nodes from all workers.
///
/// A node's table entry holds what was added to it directly. Workers flush one
/// `Totals` per directory they finish, so the lock is taken about once per
/// directory, never per file. `finish()` rolls every node up into its parent.
/// A parent is always created before its children, so a reverse pass is enough.
final class SizeAccumulator: Sendable {
    private struct State {
        var records: [NodeRecord] = []
        var totals: [Totals] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Adds a kept node and returns its index. `initial` is the node's own contribution.
    func addNode(_ record: NodeRecord, initial: Totals) -> Int {
        state.withLock { state in
            state.records.append(record)
            state.totals.append(initial)
            return state.records.count - 1
        }
    }

    /// Adds finished totals to a kept node.
    func add(_ totals: Totals, to node: Int) {
        guard !totals.isEmpty else { return }
        state.withLock { state in
            guard state.totals.indices.contains(node) else { return }
            state.totals[node].merge(totals)
        }
    }

    /// Rolls children into parents and returns the nodes sorted by depth, then path.
    func finish() -> [NodeTotal] {
        let (records, rolled) = state.withLock { state -> ([NodeRecord], [Totals]) in
            var totals = state.totals
            for index in stride(from: state.records.count - 1, to: 0, by: -1) {
                let parent = state.records[index].parent
                if parent != index, totals.indices.contains(parent) {
                    totals[parent].merge(totals[index])
                }
            }
            return (state.records, totals)
        }
        var nodes: [NodeTotal] = []
        nodes.reserveCapacity(records.count)
        for (record, total) in zip(records, rolled) {
            nodes.append(
                NodeTotal(
                    url: record.url, depth: record.depth, id: record.id, kind: record.kind, flags: record.flags,
                    allocatedBytes: total.allocated, privateBytes: total.privateBytes, fileCount: total.files,
                    newestModification: packedTimeToDate(total.newest)))
        }
        nodes.sort { lhs, rhs in
            lhs.depth != rhs.depth ? lhs.depth < rhs.depth : lhs.url.path < rhs.url.path
        }
        return nodes
    }
}

/// Hard-linked files already counted. Only entries with a link count above 1 touch it.
final class HardLinkSet: Sendable {
    private let seen = OSAllocatedUnfairLock<Set<EntryID>>(initialState: [])

    /// Returns true the first time `id` is seen.
    func firstSighting(_ id: EntryID) -> Bool {
        seen.withLock { $0.insert(id).inserted }
    }
}

/// Folders macOS refused to open. Keeps at most `capacity` paths and counts all of them.
final class DeniedList: Sendable {
    static let capacity = 500

    private struct State {
        var urls: [URL] = []
        var count = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Counts one denied folder. `makeURL` runs only while the list has room.
    func record(_ makeURL: () -> URL) {
        let needsURL = state.withLock { state -> Bool in
            state.count += 1
            return state.urls.count < Self.capacity
        }
        guard needsURL else { return }
        let url = makeURL()
        state.withLock { state in
            if state.urls.count < Self.capacity { state.urls.append(url) }
        }
    }

    /// The listed folders, sorted by path, and the total count.
    func snapshot() -> (urls: [URL], count: Int) {
        state.withLock { state in
            (state.urls.sorted { $0.path < $1.path }, state.count)
        }
    }
}

/// The N largest files seen by one worker, as a min-heap on `(allocated bytes, file ID)`.
struct TopFiles {
    let capacity: Int
    private var heap: [NodeTotal] = []

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    /// Whether a file with these values would enter the list. Check this before building a URL.
    func wouldAccept(allocated: Int64, fileID: UInt64) -> Bool {
        guard capacity > 0 else { return false }
        guard heap.count >= capacity, let smallest = heap.first else { return true }
        return Self.key(allocated, fileID) > Self.key(smallest.allocatedBytes, smallest.id.fileID)
    }

    /// Adds a file, dropping the smallest when full.
    mutating func insert(_ node: NodeTotal) {
        guard capacity > 0 else { return }
        if heap.count < capacity {
            heap.append(node)
            siftUp(heap.count - 1)
        } else if let smallest = heap.first,
            Self.key(node.allocatedBytes, node.id.fileID) > Self.key(smallest.allocatedBytes, smallest.id.fileID)
        {
            heap[0] = node
            siftDown(0)
        }
    }

    /// Largest first.
    func sortedDescending() -> [NodeTotal] {
        heap.sorted { Self.key($0.allocatedBytes, $0.id.fileID) > Self.key($1.allocatedBytes, $1.id.fileID) }
    }

    /// Merges several lists into one of `capacity` entries, largest first.
    static func merge(_ lists: [TopFiles], capacity: Int) -> [NodeTotal] {
        var merged = TopFiles(capacity: capacity)
        for list in lists {
            for node in list.heap { merged.insert(node) }
        }
        return merged.sortedDescending()
    }

    private static func key(_ allocated: Int64, _ fileID: UInt64) -> (Int64, UInt64) {
        (allocated, fileID)
    }

    private func isSmaller(_ lhs: Int, _ rhs: Int) -> Bool {
        Self.key(heap[lhs].allocatedBytes, heap[lhs].id.fileID) < Self.key(heap[rhs].allocatedBytes, heap[rhs].id.fileID)
    }

    private mutating func siftUp(_ start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard isSmaller(child, parent) else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ start: Int) {
        var parent = start
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var smallest = parent
            if left < heap.count, isSmaller(left, smallest) { smallest = left }
            if right < heap.count, isSmaller(right, smallest) { smallest = right }
            if smallest == parent { return }
            heap.swapAt(parent, smallest)
            parent = smallest
        }
    }
}
