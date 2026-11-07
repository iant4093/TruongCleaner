import Foundation

/// One component of a `GlobPattern`.
enum PatternComponent: Sendable, Equatable {
    /// Exact name (already folded).
    case literal(String)
    /// Name containing `*`, which matches any run of characters inside one component.
    case wildcard([Unicode.Scalar])
    /// `**`: zero or more whole components.
    case anyDepth
}

/// A small path glob: literal names, `*` inside a component, `**` for any depth,
/// and a leading `~` for the home folder. Matching is case-insensitive.
struct GlobPattern: Sendable {
    let components: [PatternComponent]

    /// Parses a pattern such as `~/Library/Caches/com.apple.Spotlight*/**`.
    ///
    /// - Parameter home: Components of the home folder. `~` as the first
    ///   component expands to them. Pass nil for patterns relative to a rule root.
    init(_ text: String, home: [String]? = nil) {
        var parts: [PatternComponent] = []
        let pieces = text.split(separator: "/", omittingEmptySubsequences: true)
        for (index, piece) in pieces.enumerated() {
            let name = String(piece)
            if index == 0, name == "~", let home {
                parts.append(contentsOf: home.map { .literal(PathText.fold($0)) })
            } else if name == "**" {
                parts.append(.anyDepth)
            } else if name.contains("*") {
                parts.append(.wildcard(Array(PathText.fold(name).unicodeScalars)))
            } else {
                parts.append(.literal(PathText.fold(name)))
            }
        }
        components = parts
    }

    /// Whether the pattern matches the whole path. `path` must already be folded.
    func matches(_ path: [String]) -> Bool {
        Self.match(components[...], path[...])
    }

    private static func match(_ pattern: ArraySlice<PatternComponent>, _ path: ArraySlice<String>) -> Bool {
        guard let head = pattern.first else { return path.isEmpty }
        let rest = pattern.dropFirst()
        switch head {
        case .anyDepth:
            if rest.isEmpty { return true }
            var tail = path
            while true {
                if match(rest, tail) { return true }
                if tail.isEmpty { return false }
                tail = tail.dropFirst()
            }
        case .literal(let name):
            guard let first = path.first, first == name else { return false }
            return match(rest, path.dropFirst())
        case .wildcard(let scalars):
            guard let first = path.first,
                  wildcardMatches(scalars, Array(first.unicodeScalars))
            else { return false }
            return match(rest, path.dropFirst())
        }
    }

    /// Matches `text` against `pattern` where `*` stands for any run of scalars.
    static func wildcardMatches(_ pattern: [Unicode.Scalar], _ text: [Unicode.Scalar]) -> Bool {
        var patternIndex = 0
        var textIndex = 0
        var starIndex = -1
        var resumeIndex = 0
        while textIndex < text.count {
            if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                starIndex = patternIndex
                resumeIndex = textIndex
                patternIndex += 1
            } else if patternIndex < pattern.count, pattern[patternIndex] == text[textIndex] {
                patternIndex += 1
                textIndex += 1
            } else if starIndex >= 0 {
                patternIndex = starIndex + 1
                resumeIndex += 1
                textIndex = resumeIndex
            } else {
                return false
            }
        }
        while patternIndex < pattern.count, pattern[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == pattern.count
    }
}
