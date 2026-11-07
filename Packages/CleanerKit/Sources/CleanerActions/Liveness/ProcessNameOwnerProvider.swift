import CleanerCore
import Darwin
import Foundation

/// Answers owner questions for command-line processes by name.
///
/// `.processName(x)` is `.running` when a process is named exactly `x` (its short name or the
/// last component of its executable path) and `.notRunning` otherwise. `.bundleID` is
/// `.unknown`: bundle identifiers need `NSRunningApplication`, which the app layer supplies and
/// combines with this provider through `CompositeOwnerProvider`.
///
/// `.childNameAsBundleID` is normally resolved by the gate before it asks. If it arrives anyway,
/// this provider reads the top-level folder below one of its `roots`: a name with fewer than three
/// dot-separated parts has no owner (`.notRunning`); anything else is `.unknown`, because a bundle
/// identifier cannot be matched against process names.
public struct ProcessNameOwnerProvider: RunningAppsProvider {
    private let roots: [URL]

    /// Creates a provider.
    ///
    /// - Parameter roots: The rule roots, used only to read `.childNameAsBundleID`.
    public init(roots: [URL] = []) {
        self.roots = roots
    }

    /// The state of `owner`. See the type documentation for what each spec means here.
    @concurrent
    public func state(of owner: OwnerSpec, for item: URL) async -> OwnerState {
        switch owner {
        case .processName(let name):
            return Self.isProcessRunning(named: name)
        case .bundleID:
            return .unknown
        case .childNameAsBundleID:
            guard let parts = PathParts.components(of: item) else { return .unknown }
            for root in roots {
                guard let rootParts = PathParts.components(of: root), parts.count > rootParts.count,
                    parts.starts(with: rootParts)
                else { continue }
                let pieces = parts[rootParts.count].split(separator: ".", omittingEmptySubsequences: false)
                return pieces.count < 3 || pieces.contains(where: \.isEmpty) ? .notRunning : .unknown
            }
            return .unknown
        }
    }

    /// Whether any process is named exactly `name`. `.unknown` when the process list cannot be read.
    static func isProcessRunning(named name: String) -> OwnerState {
        guard !name.isEmpty, let pids = ProcessOpenFilesProvider.allPIDs() else { return .unknown }
        for pid in pids where pid > 0 {
            var shortName = [CChar](repeating: 0, count: 256)
            if proc_name(pid, &shortName, UInt32(shortName.count)) > 0, Self.text(shortName) == name {
                return .running
            }
            var path = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                (Self.text(path) as NSString).lastPathComponent == name
            {
                return .running
            }
        }
        return .notRunning
    }

    /// The text of a NUL-terminated C character buffer.
    private static func text(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
