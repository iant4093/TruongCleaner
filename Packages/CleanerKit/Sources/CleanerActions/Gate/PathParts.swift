import Foundation

/// Path components as given, without resolving anything.
///
/// Unlike `URL.standardizedFileURL`, `.` and `..` are kept so the gate can see them and
/// leave their meaning to `realpath`, which follows the file system's rules.
enum PathParts {
    /// Components of an absolute file URL, or nil for anything else.
    static func components(of url: URL) -> [String]? {
        guard url.isFileURL else { return nil }
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix("/") else { return nil }
        return path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Whether any component is `.` or `..`.
    static func hasDotComponents(_ parts: [String]) -> Bool {
        parts.contains { $0 == "." || $0 == ".." }
    }

    /// The absolute URL for a list of components. `[]` is `/`.
    static func url(from parts: some Sequence<String>) -> URL {
        var url = URL(filePath: "/", directoryHint: .isDirectory)
        for part in parts { url.append(path: part, directoryHint: .inferFromPath) }
        return url
    }

    /// Form used to compare names on a case-insensitive volume.
    static func fold(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }
}
