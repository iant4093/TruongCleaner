import CleanerCore
import Foundation

/// The concrete folders a rule was scanned in, as `GateContext.expandedRoots` needs them.
///
/// The scan engine resolves wildcard roots itself but does not report the folders it found, so the
/// app works them out from the findings. This is pure path arithmetic. It reads no file system.
///
/// - A root without a wildcard is the expanded folder itself.
/// - A root with a wildcard becomes the ancestor of each finding that has exactly the depth of
///   the root (its base plus one folder per pattern component), starts with the expanded base, and
///   fits the root spec. No finding for a root means no folder, so nothing under it can be approved.
///
/// A wrong or missing root can only make `SafetyGate` refuse an item (`outsideRoots`); the gate
/// still resolves real paths and checks every item against these folders.
nonisolated enum ScanRoots {
    /// Concrete roots for `rule`, without duplicates, in first-found order.
    ///
    /// - Parameters:
    ///   - rule: The rule that was scanned.
    ///   - findings: What the scan found for the rule.
    ///   - environment: The environment the scan used.
    static func roots(for rule: Rule, findings: [Finding], environment: CleanerCore.Environment) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        func add(_ url: URL) {
            if seen.insert(url.path(percentEncoded: false)).inserted { result.append(url) }
        }

        for spec in rule.roots {
            guard let expanded = RootExpansion.expand(spec, in: environment) else { continue }
            if let folder = expanded.url {
                add(folder)
                continue
            }
            let base = withoutPrivatePrefix(parts(of: expanded.base))
            for finding in findings {
                let actual = parts(of: finding.url)
                let comparable = withoutPrivatePrefix(actual)
                let rootLength = base.count + expanded.pattern.count
                guard comparable.count > rootLength, comparable.starts(with: base) else { continue }
                // `/private` is one extra component that the comparison left out.
                let candidate = folder(from: actual.prefix(rootLength + actual.count - comparable.count))
                if spec.matches(concreteRoot: candidate) { add(candidate) }
            }
        }
        return result
    }

    /// Owners that each root adds for the items under it (`GateContext.rootOwners`).
    static func owners(for rule: Rule, roots: [URL]) -> [URL: [OwnerSpec]] {
        var owners: [URL: [OwnerSpec]] = [:]
        for root in roots {
            let found = rule.rootOwners(for: root)
            if !found.isEmpty { owners[root] = found }
        }
        return owners
    }

    /// Path components of an absolute URL: `/` first, then the names. A trailing `/` is dropped.
    private static func parts(of url: URL) -> [String] {
        url.pathComponents.enumerated().compactMap { index, part in
            index == 0 || part != "/" ? part : nil
        }
    }

    /// Components without a `private` that leads into `var`, `tmp` or `etc`, where the system also
    /// accepts the short form (`/var/folders` is `/private/var/folders`).
    private static func withoutPrivatePrefix(_ parts: [String]) -> [String] {
        guard parts.count > 2, parts[1] == "private", ["var", "tmp", "etc"].contains(parts[2]) else { return parts }
        return [parts[0]] + parts.dropFirst(2)
    }

    /// The folder named by absolute path components (the first is `/`).
    private static func folder(from parts: ArraySlice<String>) -> URL {
        var url = URL(filePath: "/", directoryHint: .isDirectory)
        for part in parts.dropFirst() {
            url.append(path: part, directoryHint: .isDirectory)
        }
        return url
    }
}
