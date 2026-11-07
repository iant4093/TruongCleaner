import CleanerScanner
import Foundation

/// One folder, file or merged "Other" group in a Space Lens tree.
///
/// Values are plain data so the tree can be built off the main actor.
nonisolated struct LensNode: Sendable, Identifiable {
    nonisolated enum Kind: Sendable {
        case folder
        case file
        /// Several small items merged into one slice. It has no location.
        case other
    }

    /// Unique inside one tree.
    let id: Int
    /// Location on disk. `nil` for merged "Other" groups.
    let url: URL?
    let name: String
    /// Allocated bytes on disk for the whole subtree. 0 for a folder that could not be read.
    let bytes: Int64
    let kind: Kind
    /// True when macOS refused to open this folder. Its size is unknown, not zero.
    let isDenied: Bool
    /// How many items an "Other" group stands for. 1 for everything else.
    let itemCount: Int
    /// Largest first. Never more than ``LensTree/maxChildren`` entries plus one "Other" group.
    let children: [LensNode]

    /// A folder the user can open as the new lens root.
    var isExplorable: Bool { kind == .folder && !isDenied && url != nil }
}

/// What Space Lens shows for one scanned folder: the node tree to depth 3 and the sunburst layout built from it.
nonisolated final class LensTree: Sendable {
    /// Most children kept per node. The rest are merged into one "Other" group.
    static let maxChildren = 40

    /// Identifies this scan result, for view identity.
    let id = UUID()
    let root: LensNode
    let layout: SunburstLayout
    /// Folders macOS would not open anywhere below the root. Their size is not in any total.
    let deniedCount: Int
    /// Files counted in the walk.
    let fileCount: Int

    init(root: LensNode, deniedCount: Int, fileCount: Int) {
        self.root = root
        self.layout = SunburstLayout(root: root)
        self.deniedCount = deniedCount
        self.fileCount = fileCount
    }

    /// Builds the tree and its layout from a walk result, off the main actor.
    @concurrent
    static func build(from result: WalkResult) async -> LensTree {
        var builder = Builder(result: result)
        let root = builder.makeRoot()
        return LensTree(root: root, deniedCount: result.deniedCount, fileCount: result.files)
    }

    /// Turns the flat, depth-sorted node list into a tree.
    private struct Builder {
        private var nextID = 0
        private let rootNode: NodeTotal?
        private let childrenByParent: [String: [NodeTotal]]
        private let denied: Set<String>

        init(result: WalkResult) {
            var grouped: [String: [NodeTotal]] = [:]
            for node in result.nodes where node.depth >= 1 {
                grouped[node.url.deletingLastPathComponent().path, default: []].append(node)
            }
            rootNode = result.nodes.first
            childrenByParent = grouped
            denied = Set(result.deniedDirectories.map { $0.path })
        }

        mutating func makeRoot() -> LensNode {
            guard let rootNode else {
                return LensNode(
                    id: 0, url: nil, name: "", bytes: 0, kind: .folder, isDenied: false, itemCount: 1, children: [])
            }
            return make(rootNode)
        }

        private mutating func make(_ node: NodeTotal) -> LensNode {
            let id = nextID
            nextID += 1
            let isFolder = node.kind == .directory
            let children = isFolder ? makeChildren(of: node) : []
            let name = node.url.lastPathComponent
            return LensNode(
                id: id, url: node.url, name: name.isEmpty ? "/" : name, bytes: node.allocatedBytes,
                kind: isFolder ? .folder : .file, isDenied: denied.contains(node.url.path), itemCount: 1,
                children: children)
        }

        private mutating func makeChildren(of node: NodeTotal) -> [LensNode] {
            // Empty items add nothing to a size chart. Unreadable folders stay so the list can say why.
            let candidates = (childrenByParent[node.url.path] ?? []).filter {
                $0.allocatedBytes > 0 || denied.contains($0.url.path)
            }
            let sorted = candidates.sorted { left, right in
                if left.allocatedBytes != right.allocatedBytes { return left.allocatedBytes > right.allocatedBytes }
                return left.url.lastPathComponent.localizedStandardCompare(right.url.lastPathComponent)
                    == .orderedAscending
            }
            var result = sorted.prefix(LensTree.maxChildren).map { make($0) }
            let rest = sorted.dropFirst(LensTree.maxChildren)
            if !rest.isEmpty {
                let id = nextID
                nextID += 1
                result.append(
                    LensNode(
                        id: id, url: nil, name: "Other", bytes: rest.reduce(0) { $0 + $1.allocatedBytes },
                        kind: .other, isDenied: false, itemCount: rest.count, children: []))
            }
            return result
        }
    }
}
