import Foundation

/// Formats byte counts the way Finder does, so every size in the app reads the same.
public enum ByteFormatter {
    /// Returns a Finder-style size such as "12.4 GB".
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatStyle(style: .file).format(bytes)
    }
}
