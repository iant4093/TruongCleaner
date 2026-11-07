import Foundation

/// A rule root after its base has been resolved against an `Environment`.
///
/// When the spec has no wildcard, `pattern` is empty and `url` is the folder.
/// When it has one, `base` is the folder before the first wildcard component and
/// `pattern` holds the components from that wildcard on. The scanner resolves
/// the pattern against the real file system; this module never does.
public struct ExpandedRoot: Sendable, Hashable {
    /// The folder before the first wildcard component (or the whole root when concrete).
    public let base: URL
    /// Components from the first wildcard on. Empty when the root is concrete.
    public let pattern: [String]

    /// Creates an expanded root.
    public init(base: URL, pattern: [String]) {
        self.base = base
        self.pattern = pattern
    }

    /// True when the root names one folder and needs no resolving.
    public var isConcrete: Bool { pattern.isEmpty }

    /// The root folder when it is concrete, otherwise nil.
    public var url: URL? { isConcrete ? base : nil }
}

/// Turns `RootSpec` values into folder URLs.
public enum RootExpansion {
    /// Expands a root spec against the environment.
    ///
    /// Components containing `*` are not resolved here; they are returned in
    /// `ExpandedRoot.pattern` for the scanner.
    ///
    /// - Returns: nil when the base is unknown (for example no Darwin cache
    ///   directory) or a component is unsafe (`""`, `.`, `..`, or contains `/`).
    ///   Unknown means no root, so nothing is scanned. Also nil for `RootSpec.Base.userChosen`,
    ///   which stands for several folders: use `starts(of:in:)` and `expand(_:from:)`.
    public static func expand(_ spec: RootSpec, in env: Environment) -> ExpandedRoot? {
        guard spec.base != .userChosen, let start = starts(of: spec, in: env).first else { return nil }
        return expand(spec, from: start)
    }

    /// The folders a spec's components start from: the one base folder, or each chosen project
    /// folder for `RootSpec.Base.userChosen`.
    ///
    /// Empty when the base is unknown. For project folders, a folder is dropped when the protected
    /// list covers it or it is a folder we never delete from the top (`/`, `~`, `~/Library`, ...),
    /// when it is not an absolute file URL, or when it repeats an earlier one.
    public static func starts(of spec: RootSpec, in env: Environment) -> [URL] {
        switch spec.base {
        case .home:
            return [env.home]
        case .absolute:
            return [URL(filePath: "/", directoryHint: .isDirectory)]
        case .darwinUserCache:
            return env.darwinUserCache.map { [$0] } ?? []
        case .darwinUserTemp:
            return env.darwinUserTemp.map { [$0] } ?? []
        case .userChosen:
            return chosenFolders(in: env)
        }
    }

    /// Expands a spec's components below one starting folder from `starts(of:in:)`.
    ///
    /// - Returns: nil when the start is not an absolute file URL or a component is unsafe.
    public static func expand(_ spec: RootSpec, from start: URL) -> ExpandedRoot? {
        guard PathText.components(of: start) != nil else { return nil }

        var base = start
        var pattern: [String] = []
        for component in spec.components {
            guard isSafe(component) else { return nil }
            if !pattern.isEmpty || component.contains("*") {
                pattern.append(component)
            } else {
                base.append(path: component, directoryHint: .isDirectory)
            }
        }
        return ExpandedRoot(base: base, pattern: pattern)
    }

    private static func chosenFolders(in env: Environment) -> [URL] {
        let policy = PathPolicy(environment: env, userExclusions: [])
        var seen: Set<String> = []
        var folders: [URL] = []
        for folder in env.projectFolders {
            guard let parts = PathText.components(of: folder),
                  policy.protectedReason(for: folder) == nil,
                  !policy.isRoot(folder, roots: []),
                  seen.insert(PathText.key(parts.map(PathText.fold))).inserted
            else { continue }
            folders.append(folder)
        }
        return folders
    }

    private static func isSafe(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.contains("/")
            && !component.contains("\0")
    }
}
