import CleanerCore
import Foundation

/// Where a walk is inside a `.glob` pattern. Carried by every directory job of a filtered walk.
struct DescentCursor: Sendable {
    /// True inside a folder that is itself a match, or after a `**`: everything below is walked.
    var free: Bool
    /// Indices of the pattern alternatives whose first components match the path so far.
    /// Empty when `free`.
    var live: [UInt16]

    /// Nothing is filtered. Used when the walk has no filter.
    static let everything = DescentCursor(free: true, live: [])
}

/// Decides which folders a walk for a `.glob` rule opens at all.
///
/// A glob such as `Install macOS*.app` can only match a direct child of the root with that name. Opening
/// every other folder of `/Applications` (229,000 files on one Mac) cannot change the answer, so the
/// walker leaves them alone. The rule: a folder is opened when
/// - it is a match, or lies inside one (its size is the size of the item, so it is read in full), or
/// - the components so far agree with the start of some pattern alternative (a match may be below), or
/// - a `**` has been reached, after which any folder may hold a match.
///
/// Any doubt opens the folder: a name that is not valid UTF-8 is opened, and a component that
/// `GlobPattern` would read more loosely is read loosely here too. Fewer folders are opened, never
/// different matches.
///
/// The filter does not change totals of anything it opens. Folders it skips get no node and add no
/// bytes, so a skipped folder's size is not known; it is never a match.
struct DescentFilter: Sendable {
    private struct Part: Sendable {
        /// `**`
        let anyDepth: Bool
        /// A single-component pattern: literal or with `*`.
        let pattern: GlobPattern?
    }

    private let alternatives: [[Part]]
    /// Alternatives with at least one component, as the starting cursor.
    private let start: [UInt16]

    /// The filter for `rule`, or nil when it could not skip anything: not a `.glob` rule, an Info rule, a
    /// pattern that starts with `**` (every folder may lead to a match), or no usable pattern.
    init?(rule: Rule) {
        guard rule.tier != .info, case .glob(let text) = rule.match else { return nil }
        var parsed: [[Part]] = []
        for alternative in GlobPrune.alternatives(of: text) {
            let names = alternative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if names.first == "**" { return nil }
            parsed.append(names.map { name in
                name == "**" ? Part(anyDepth: true, pattern: nil) : Part(anyDepth: false, pattern: GlobPattern(name))
            })
        }
        guard !parsed.isEmpty, parsed.count <= Int(UInt16.max) else { return nil }
        alternatives = parsed
        start = parsed.indices.filter { !parsed[$0].isEmpty }.map { UInt16($0) }
    }

    /// The cursor for the root folder.
    var rootCursor: DescentCursor { DescentCursor(free: false, live: start) }

    /// The cursor for the subfolder `name` of a folder at `depth` below the root (the root is 0), or nil
    /// when the folder cannot hold or be a match and need not be opened.
    func enter(_ name: UnsafePointer<CChar>, from parent: DescentCursor, depth: Int) -> DescentCursor? {
        if parent.free { return parent }
        guard let text = String(validatingCString: name) else { return .everything }
        let folded = text.precomposedStringWithCanonicalMapping.lowercased()
        var live: [UInt16] = []
        for index in parent.live {
            let parts = alternatives[Int(index)]
            guard depth < parts.count else { continue }
            let part = parts[depth]
            if part.anyDepth { return .everything }
            guard let pattern = part.pattern, pattern.matches([folded]) else { continue }
            // The last component matched: this folder is an item of the rule.
            if depth + 1 == parts.count { return .everything }
            live.append(index)
        }
        return live.isEmpty ? nil : DescentCursor(free: false, live: live)
    }
}
