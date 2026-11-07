import Darwin
import Foundation

/// Whether the app can read folders that macOS protects with Full Disk Access.
public enum AccessState: Sendable, Equatable {
    /// At least one protected folder could be read.
    case granted
    /// Every protected folder that exists refused to open (`EPERM`/`EACCES`).
    case notGranted
    /// The probes did not give a clear answer, for example no probed folder exists.
    case unknown
}

/// Tells whether Full Disk Access is on, by trying to read a few protected folders.
///
/// Only read-only calls are made: `opendir` and one `readdir`. A small fixed list is
/// probed because denied opens are slow (spike S2: probing every container took 2.7 s).
public enum AccessProbe {
    /// The protected folders probed under a home folder, in order.
    ///
    /// - Parameter home: The user's home folder.
    public static func defaultPaths(home: URL) -> [URL] {
        let library = home.appending(path: "Library", directoryHint: .isDirectory)
        return [
            library.appending(path: "Safari", directoryHint: .isDirectory),
            library.appending(path: "Mail", directoryHint: .isDirectory),
            library.appending(path: "Messages", directoryHint: .isDirectory),
            library.appending(path: "Containers", directoryHint: .isDirectory)
                .appending(path: "com.apple.stocks", directoryHint: .isDirectory),
        ]
    }

    /// Probes the default protected folders under `home`. Runs off the caller's actor.
    ///
    /// - Parameter home: The user's home folder.
    @concurrent
    public static func fullDiskAccess(home: URL) async -> AccessState {
        state(probing: defaultPaths(home: home))
    }

    /// Probes the given folders. Runs off the caller's actor. Tests pass fixture folders.
    ///
    /// - Parameter paths: Folders to try to open.
    @concurrent
    public static func fullDiskAccess(probing paths: [URL]) async -> AccessState {
        state(probing: paths)
    }

    /// Blocking version of the probe.
    ///
    /// `granted` when any folder is readable. `notGranted` when at least one folder exists and
    /// every existing folder was refused. `unknown` otherwise (nothing exists, or a folder failed
    /// for another reason). Nothing is cached.
    ///
    /// - Parameter paths: Folders to try to open.
    static func state(probing paths: [URL]) -> AccessState {
        var existing = 0
        var denied = 0
        for url in paths {
            switch readFirstEntry(of: url) {
            case .readable:
                return .granted
            case .failed(ENOENT):
                continue
            case .failed(let code) where code == EPERM || code == EACCES:
                existing += 1
                denied += 1
            case .failed:
                existing += 1
            }
        }
        return existing > 0 && denied == existing ? .notGranted : .unknown
    }

    private enum Outcome: Equatable {
        case readable
        case failed(Int32)
    }

    /// `opendir` plus `readdir` until one real entry. An empty folder counts as readable.
    private static func readFirstEntry(of url: URL) -> Outcome {
        guard let dir = opendir(url.path(percentEncoded: false)) else { return .failed(errno) }
        defer { closedir(dir) }
        errno = 0
        while let entry = readdir(dir) {
            if !isDotEntry(entry) { return .readable }
        }
        let code = errno
        return code == 0 ? .readable : .failed(code)
    }

    private static func isDotEntry(_ entry: UnsafeMutablePointer<dirent>) -> Bool {
        withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
            let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
            let name = bytes[..<end]
            return name.elementsEqual(".".utf8) || name.elementsEqual("..".utf8)
        }
    }
}
