import CleanerCore
import CleanerScanner
import Darwin
import Foundation

/// The one door every deletion passes through (`.kiro/steering/safety.md`, rule 1).
///
/// `authorize` re-checks a finding against the file system and the running system
/// just before it is acted on. Preview and clean call the same method (rule 15),
/// so a preview shows exactly what a clean would skip.
///
/// Any failed check, thrown error or unexpected `errno` denies the item. Nothing is cached.
public struct SafetyGate: Sendable {
    /// Extensions of code bundles. Nothing in or below a path with one of these is ever changed.
    static let bundleExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "appex", "kext", "xpc",
        "qlgenerator", "prefpane", "saver", "mdimporter", "driver",
    ]

    /// Paths inside a folder that make it a real bundle (any one is enough).
    private static let bundleMarkers: [[String]] = [
        ["Contents", "Info.plist"], ["Info.plist"], ["Contents", "_CodeSignature"],
    ]

    /// Longest the age check may spend walking a folder.
    private static let ageWalkLimit: Duration = .seconds(5)

    /// Creates a gate.
    public init() {}

    /// Decides whether one finding may be acted on right now.
    ///
    /// Checks run cheapest first and the first failure decides:
    /// 1. Info rule or no action.
    /// 2. The parent's real path is resolved; the item itself is never resolved.
    /// 3. User exclusion.
    /// 4. Inside one of the rule's roots.
    /// 5. Not a root.
    /// 6. Global protected list.
    /// 7. No symlink between the root and the item.
    /// 8. Not a code bundle or inside one. A folder counts as a bundle only when its extension is
    ///    a bundle extension and it holds `Contents/Info.plist`, `Info.plist` or `Contents/_CodeSignature`.
    /// 9. Exists, and no `SF_RESTRICTED`, `SF_NOUNLINK`, immutable or append-only flag.
    /// 10. `(fsid, fileID)` unchanged since the scan.
    /// 11. `minAge`, then `keepNewest`.
    /// 12. Owners not running: the rule's owners plus the owners of the root the item lies under.
    /// 13. No process has a file open inside.
    ///
    /// - Parameters:
    ///   - finding: The item as the scan recorded it.
    ///   - rule: The rule that produced the finding.
    ///   - context: Roots, policy, clock and liveness providers.
    /// - Returns: `.allow` only when every check passed.
    @concurrent
    public func authorize(_ finding: Finding, rule: Rule, context: GateContext) async -> Verdict {
        do {
            if let reason = try await evaluate(finding, rule: rule, context: context) {
                return .deny(reason)
            }
            return .allow
        } catch let error as SysError {
            return .deny(error.isMissing ? .missing : .probeFailed(error.description))
        } catch {
            return .deny(.probeFailed("unexpected error"))
        }
    }

    // MARK: - Checks

    private func evaluate(_ finding: Finding, rule: Rule, context: GateContext) async throws -> DenyReason? {
        // 1. Info rows never delete.
        if rule.tier == .info || rule.action == .none { return .infoRule }

        // 2. Resolve the parent's real path. The item's own last component is never resolved.
        guard let given = PathParts.components(of: finding.url) else { return .outsideRoots }
        guard let name = given.last else { return .isRoot }
        if name == "." || name == ".." { return .outsideRoots }
        let realParent = try GateSystem.realPath(of: PathParts.url(from: given.dropLast()))
        let item = realParent.appending(path: name, directoryHint: .inferFromPath)

        // 3. User exclusions win over everything below.
        let protected = context.policy.protectedReason(for: item)
        if protected == .userExcluded { return .userExcluded }

        // 4. Inside a root, by real path, and (when the path has no `..`) by the path as scanned.
        // A root that `excludeRootSegments` leaves out is not one of the rule's roots.
        let roots = context.expandedRoots.filter { !rule.excludesRoot($0) }
        let rootPairs = roots.compactMap { root in
            (try? GateSystem.realPath(of: root)).map { RootPair(expanded: root, real: $0) }
        }
        let realRoots = rootPairs.map(\.real)
        let given4 = givenPath(given, roots: roots + realRoots)
        guard context.policy.isInside(item, roots: realRoots) else {
            if let given4, (try? hasSymlink(below: given4)) == true { return .symlinkAncestor }
            return .outsideRoots
        }
        if !PathParts.hasDotComponents(given), given4 == nil { return .outsideRoots }

        // 5. Children only.
        if context.policy.isRoot(item, roots: realRoots) { return .isRoot }

        // 6. Protected list.
        if let protected { return .protectedPath(protected) }

        // 7. A symlinked ancestor on the path as scanned makes the item ineligible.
        if let given4, try hasSymlink(below: given4) { return .symlinkAncestor }

        // 8. No bundle edits.
        if try touchesBundle(item, allowWholeBundle: context.allowWholeBundle) { return .insideBundle }

        // 9. Exists, and macOS allows removing it.
        let info = try GateSystem.lstatInfo(of: item)
        if GateSystem.isMacOSProtected(flags: info.st_flags) { return .macOSProtected }
        if GateSystem.isDirectory(info) {
            let parentInfo = try GateSystem.lstatInfo(of: realParent)
            if GateSystem.isMacOSProtected(flags: parentInfo.st_flags) { return .macOSProtected }
        }

        // 10. Still the same file system entry the scan saw.
        let current = try GateSystem.identity(of: item)
        if current.fsid != finding.fsid || current.fileID != finding.fileID { return .changedSinceScan }

        // 11. Age and keep-newest still hold.
        if let minAge = rule.guards.minAge {
            guard let newest = await newestModification(of: item, info: info) else { return .unknownAge }
            if context.environment.now.timeIntervalSince(newest) <= Self.seconds(minAge) { return .tooNew }
        }
        if let keep = rule.guards.keepNewest, keep > 0,
            try isAmongNewest(keep, item: item, parent: realParent)
        {
            return .keepNewest
        }

        // 12. Owners are closed. Unknown means keep.
        let root = OwnerResolution.deepestRoot(containing: item, in: realRoots)
        guard let owners = Self.effectiveOwners(rule: rule, root: root, pairs: rootPairs, context: context) else {
            return .ownerUnknown
        }
        for owner in owners {
            switch OwnerResolution.target(for: owner, item: item, root: root, rootSpecs: rule.roots) {
            case .noOwner:
                continue
            case .unresolvable:
                return .ownerUnknown
            case .ask(let spec):
                switch await context.runningApps.state(of: spec, for: item) {
                case .running: return .ownerOpen(Self.label(for: spec))
                case .unknown: return .ownerUnknown
                case .notRunning: break
                }
            }
        }

        // 13. Nothing has it open. Unknown means keep.
        switch await context.openFiles.hasOpenFiles(under: item) {
        case true?: return .openFiles
        case nil: return .openFilesUnknown
        case false?: break
        }
        return nil
    }

    // MARK: - Helpers

    /// The path as given, as a list of components, when it has no `.`/`..` and lies under one of `roots`
    /// (compared by whole components, case-sensitive). Nil otherwise.
    private func givenPath(_ given: [String], roots: [URL]) -> GivenPath? {
        guard !PathParts.hasDotComponents(given) else { return nil }
        var best: Int?
        for root in roots {
            guard let rootParts = PathParts.components(of: root), !PathParts.hasDotComponents(rootParts),
                given.starts(with: rootParts)
            else { continue }
            best = max(best ?? 0, rootParts.count)
        }
        guard let best else { return nil }
        return GivenPath(parts: given, rootCount: best)
    }

    /// Whether a folder strictly between the root and the item (on the path as given) is a symlink.
    private func hasSymlink(below path: GivenPath) throws -> Bool {
        guard path.parts.count > path.rootCount + 1 else { return false }
        for length in (path.rootCount + 1)..<path.parts.count {
            let folder = PathParts.url(from: path.parts.prefix(length))
            if GateSystem.isSymlink(try GateSystem.lstatInfo(of: folder)) { return true }
        }
        return false
    }

    /// Whether the item, or any folder above it, is a code bundle. The one exception is the item
    /// itself being a `.app` when the rule allows whole-bundle removal.
    ///
    /// A name with a bundle extension is not enough: a cache folder called `com.example.App` is just
    /// a folder. It counts only when it is a real folder (not a link) that holds a bundle marker.
    /// A marker that cannot be read throws, so the item is kept.
    private func touchesBundle(_ item: URL, allowWholeBundle: Bool) throws -> Bool {
        guard let parts = PathParts.components(of: item) else { return true }
        for (index, part) in parts.enumerated() {
            let ext = PathParts.fold((part as NSString).pathExtension)
            guard Self.bundleExtensions.contains(ext) else { continue }
            if index == parts.count - 1, allowWholeBundle, ext == "app" { continue }
            if try isRealBundle(PathParts.url(from: parts.prefix(index + 1))) { return true }
        }
        return false
    }

    /// Whether `folder` is a folder holding `Contents/Info.plist`, `Info.plist` or `Contents/_CodeSignature`.
    /// A path that does not exist is not a bundle.
    private func isRealBundle(_ folder: URL) throws -> Bool {
        do {
            guard GateSystem.isDirectory(try GateSystem.lstatInfo(of: folder)) else { return false }
        } catch let error as SysError where error.isMissing {
            return false
        }
        for marker in Self.bundleMarkers {
            var url = folder
            for component in marker { url.append(path: component, directoryHint: .inferFromPath) }
            do {
                _ = try GateSystem.lstatInfo(of: url)
                return true
            } catch let error as SysError where error.isMissing {
                continue
            }
        }
        return false
    }

    /// Newest modification date inside the item (the item's own date for a file or link).
    /// Nil when the date cannot be known completely: partial walk, unreadable folder, error.
    private func newestModification(of item: URL, info: stat) async -> Date? {
        guard GateSystem.isDirectory(info) else { return GateSystem.modificationDate(info) }
        let options = WalkOptions(maxWorkers: 2, totalsDepth: 0, topFilesCount: 0, limit: Self.ageWalkLimit)
        guard let result = try? await BulkWalker.walk(item, options: options) else { return nil }
        guard !result.partial, result.deniedCount == 0, result.otherErrors == 0 else { return nil }
        return result.nodes.first?.newestModification
    }

    /// Whether fewer than `keep` siblings are strictly newer than the item, by the date of each
    /// sibling in a fresh listing of the parent. Ties count as "not newer", so a tie keeps the item.
    private func isAmongNewest(_ keep: Int, item: URL, parent: URL) throws -> Bool {
        let name = try Self.lastComponentBytes(of: item)
        let children = try GateSystem.children(of: parent)
        guard let own = children.first(where: { $0.name == name }) else {
            throw SysError(call: "getattrlistbulk", code: ENOENT)
        }
        guard let ownDate = own.modified else { throw SysError(call: "getattrlistbulk", code: EIO) }
        let newer = children.reduce(0) { count, child in
            guard child.name != name, let date = child.modified, date > ownDate else { return count }
            return count + 1
        }
        return newer < keep
    }

    /// The owners to check for an item: the rule's own, then those of the root it lies under
    /// (from the rule's root specs and from `context.rootOwners`), without duplicates.
    ///
    /// - Returns: nil when the item's root cannot be found but some root carries owners. Those
    ///   owners cannot be applied, so the caller keeps the item.
    private static func effectiveOwners(
        rule: Rule, root: URL?, pairs: [RootPair], context: GateContext
    ) -> [OwnerSpec]? {
        var owners = rule.guards.owners
        guard let root else {
            let needed = !context.rootOwners.isEmpty || rule.roots.contains { !$0.owners.isEmpty }
            return needed ? nil : owners
        }
        let wanted = Set(
            [root] + pairs.filter { key($0.real) == key(root) }.map(\.expanded)
        ).compactMap(key)
        var rootLevel = rule.rootOwners(for: root)
        for (url, list) in context.rootOwners {
            if let name = key(url), wanted.contains(name) { rootLevel += list }
        }
        for owner in rootLevel where !owners.contains(owner) { owners.append(owner) }
        return owners
    }

    /// Case-insensitive identity of a folder path, for comparing roots.
    private static func key(_ url: URL) -> String? {
        PathParts.components(of: url)?.map(PathParts.fold).joined(separator: "/")
    }

    /// The name to show when an owner is running.
    private static func label(for owner: OwnerSpec) -> String {
        switch owner {
        case .bundleID(let id): id
        case .processName(let name): name
        case .childNameAsBundleID, .rootSegmentAsBundleID: "its app"
        }
    }

    /// The bytes of the last path component as the file system sees them.
    private static func lastComponentBytes(of url: URL) throws -> [UInt8] {
        try GateSystem.withPath(url) { path in
            let bytes = Array(UnsafeBufferPointer(start: path, count: strlen(path))).map { UInt8(bitPattern: $0) }
            let slash = UInt8(ascii: "/")
            guard let last = bytes.lastIndex(of: slash) else { return bytes }
            return Array(bytes[(last + 1)...])
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) * 1e-18
    }
}

/// A rule root as scanned, with its real path.
private struct RootPair {
    let expanded: URL
    let real: URL
}

/// A path as the finding gave it, split at the rule root it lies under.
private struct GivenPath {
    let parts: [String]
    /// Number of leading components that make up the matching root.
    let rootCount: Int
}
