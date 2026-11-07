import Foundation

/// Errors thrown by the scanner before or instead of producing a result.
///
/// Problems with individual files or folders inside a walk are not thrown.
/// They appear as counts and lists in the result.
public enum ScanError: Error, Sendable, Equatable {
    /// The scan root is not a folder, or it is a symbolic link. Roots are never followed.
    case notADirectory(URL)
    /// macOS refused access to the scan root (`EPERM` or `EACCES`).
    case accessDenied(URL)
    /// The scan root could not be opened for another reason.
    case cannotOpen(URL, errno: Int32)

    /// A short sentence for the user, in plain words.
    public var userMessage: String {
        switch self {
        case .notADirectory(let url):
            "“\(url.lastPathComponent)” is not a folder."
        case .accessDenied(let url):
            "TruongCleaner needs access to “\(url.lastPathComponent)”."
        case .cannotOpen(let url, _):
            "“\(url.lastPathComponent)” could not be opened."
        }
    }

    /// Technical detail for logs. Contains the full path, so log it as private.
    public var debugDetail: String {
        switch self {
        case .notADirectory(let url):
            "not a directory (or a symlink): \(url.path)"
        case .accessDenied(let url):
            "access denied: \(url.path)"
        case .cannotOpen(let url, let code):
            "cannot open \(url.path): errno \(code) (\(String(cString: strerror(code))))"
        }
    }
}
