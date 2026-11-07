import CleanerCore
import Darwin
import Foundation

/// Reads the values a scan or a clean needs from the running system.
nonisolated enum ScanEnvironment {
    /// The home folder, the per-user Darwin directories and the clock.
    ///
    /// A Darwin directory that cannot be read is `nil`; rules that need it then scan nothing.
    static func current(now: Date = Date()) -> CleanerCore.Environment {
        CleanerCore.Environment(
            home: FileManager.default.homeDirectoryForCurrentUser,
            darwinUserCache: directory(_CS_DARWIN_USER_CACHE_DIR),
            darwinUserTemp: directory(_CS_DARWIN_USER_TEMP_DIR),
            now: now
        )
    }

    /// The folder `confstr` names, or nil when it is not available.
    private static func directory(_ name: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let needed = confstr(name, &buffer, buffer.count)
        guard needed > 1, needed <= buffer.count else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        guard path.hasPrefix("/") else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }
}
