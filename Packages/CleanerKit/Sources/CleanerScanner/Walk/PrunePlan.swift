import Foundation

/// Where a folder sits relative to a pruned folder (`WalkOptions.pruneNames`).
enum PruneState: UInt8, Sendable {
    /// Not a pruned folder and not below one. Everything is kept as usual.
    case none
    /// The pruned folder itself. It has its own node; only its listed direct children may have one too.
    case top
    /// Anywhere below a pruned folder. Nothing is kept; totals go into the pruned folder's node.
    case inside
}

/// The names `WalkOptions.pruneNames` and `pruneKeepNames` stand for, as lowercase ASCII bytes.
///
/// Names are compared on raw bytes with ASCII case folded, so a lookup allocates nothing. Whatever
/// cannot be compared that way errs towards keeping more nodes, never fewer:
/// - a pruned name with non-ASCII characters is dropped (the folder is simply not pruned);
/// - a direct child of a pruned folder with non-ASCII characters in its name always keeps its node.
struct PrunePlan: Sendable {
    private let names: [[UInt8]]
    private let keepNames: [[UInt8]]

    /// A plan that prunes nothing.
    static let off = PrunePlan(names: [], keepNames: [])

    /// True when at least one folder name can be pruned.
    var isActive: Bool { !names.isEmpty }

    init(_ options: WalkOptions) {
        self.init(names: options.pruneNames, keepNames: options.pruneKeepNames)
    }

    init(names: Set<String>, keepNames: Set<String>) {
        self.names = Self.bytes(of: names)
        self.keepNames = Self.bytes(of: keepNames)
    }

    /// The state of a subfolder named `name` (NUL-terminated) of a folder in state `parent`.
    func state(ofChildNamed name: UnsafePointer<CChar>, parent: PruneState) -> PruneState {
        switch parent {
        case .inside, .top:
            return .inside
        case .none:
            guard isActive else { return .none }
            let length = strlen(name)
            return names.contains { Self.equals($0, name, length: length) } ? .top : .none
        }
    }

    /// Whether an entry named `name` (NUL-terminated) inside a folder in state `parent` keeps its own node.
    /// Depth limits (`totalsDepth`) apply on top of this.
    func keepsNode(childNamed name: UnsafePointer<CChar>, parent: PruneState) -> Bool {
        switch parent {
        case .none:
            return true
        case .inside:
            return false
        case .top:
            let length = strlen(name)
            return Self.hasNonASCII(name, length: length)
                || keepNames.contains { Self.equals($0, name, length: length) }
        }
    }

    // MARK: - Private

    private static func bytes(of names: Set<String>) -> [[UInt8]] {
        names.compactMap { name -> [UInt8]? in
            let raw = Array(name.utf8)
            guard !raw.isEmpty, raw.allSatisfy({ $0 < 0x80 }) else { return nil }
            return raw.map { lowercased($0) }
        }
        .sorted { $0.lexicographicallyPrecedes($1) }
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte + 0x20 : byte
    }

    private static func equals(_ stored: [UInt8], _ name: UnsafePointer<CChar>, length: Int) -> Bool {
        guard stored.count == length else { return false }
        for index in 0..<length where lowercased(UInt8(bitPattern: name[index])) != stored[index] {
            return false
        }
        return true
    }

    private static func hasNonASCII(_ name: UnsafePointer<CChar>, length: Int) -> Bool {
        for index in 0..<length where UInt8(bitPattern: name[index]) >= 0x80 {
            return true
        }
        return false
    }
}
