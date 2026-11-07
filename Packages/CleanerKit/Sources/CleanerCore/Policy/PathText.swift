import Foundation

/// Lexical path helpers. Nothing here touches the file system.
enum PathText {
    /// Components of an absolute file URL with `.` and `..` resolved lexically.
    ///
    /// `Foundation`'s `standardizedFileURL` is avoided on purpose: it can drop a
    /// leading `/private`, which would hide `/private/etc` and `/private/var/db`
    /// from the protected list.
    ///
    /// - Returns: nil when the URL is not a file URL or not absolute.
    static func components(of url: URL) -> [String]? {
        guard url.isFileURL else { return nil }
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix("/") else { return nil }
        var result: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".":
                continue
            case "..":
                if !result.isEmpty { result.removeLast() }
            default:
                result.append(String(part))
            }
        }
        return result
    }

    /// Form used to compare names on a case-insensitive, normalization-insensitive
    /// volume (the macOS default).
    static func fold(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Drops a leading `/System/Volumes/Data` so a path scanned from the Data
    /// volume is judged like its firmlinked twin (`/Users/...`, not `/System/...`).
    static func canonical(_ components: [String]) -> [String] {
        guard components.count >= 3,
              fold(components[0]) == "system",
              fold(components[1]) == "volumes",
              fold(components[2]) == "data"
        else { return components }
        return Array(components.dropFirst(3))
    }

    /// Key for dictionaries indexed by folder.
    static func key(_ components: [String]) -> String {
        components.joined(separator: "/")
    }
}
