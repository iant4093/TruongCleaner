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
    ///   Unknown means no root, so nothing is scanned.
    public static func expand(_ spec: RootSpec, in env: Environment) -> ExpandedRoot? {
        let start: URL
        switch spec.base {
        case .home:
            start = env.home
        case .absolute:
            start = URL(filePath: "/", directoryHint: .isDirectory)
        case .darwinUserCache:
            guard let url = env.darwinUserCache else { return nil }
            start = url
        case .darwinUserTemp:
            guard let url = env.darwinUserTemp else { return nil }
            start = url
        }
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

    private static func isSafe(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.contains("/")
            && !component.contains("\0")
    }
}
