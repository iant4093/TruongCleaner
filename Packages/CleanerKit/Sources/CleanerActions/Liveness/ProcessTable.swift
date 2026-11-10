import Darwin
import Foundation

/// What `sysctl(KERN_PROCARGS2)` gave for one process.
enum ProcessArguments: Equatable {
    /// The executable path and the argument vector.
    case read(executable: String, argv: [String])
    /// The process ended while it was read.
    case gone
    /// The system refused or the buffer made no sense.
    case unreadable
}

/// Small wrappers over libproc and `sysctl` for questions about running processes.
///
/// Reads only. Nothing here changes a process or a file.
enum ProcessTable {
    /// Process IDs, or nil when the list cannot be read.
    static func allPIDs() -> [Int32]? { ProcessInspector.allPIDs() }

    /// The owner of a process, or nil when it cannot be read (ended, or the system refused).
    static func ownerUID(of pid: Int32) -> UInt32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_uid
    }

    /// Whether the process belongs to the current user. Nil when that cannot be told.
    static func belongsToCurrentUser(_ pid: Int32) -> Bool? {
        ownerUID(of: pid).map { $0 == getuid() }
    }

    /// The short name of a process (`proc_name`), or nil.
    static func shortName(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return text(buffer)
    }

    /// The executable path of a process (`proc_pidpath`), or nil.
    static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return text(buffer)
    }

    /// The largest argument area the kernel hands out (`kern.argmax`), or 1 MiB if unreadable.
    static let argumentLimit: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 1 << 20 }
        return Int(value)
    }()

    /// Reads the argument vector of a process (`KERN_PROCARGS2`).
    ///
    /// - Parameters:
    ///   - pid: The process.
    ///   - buffer: Scratch space of at least ``argumentLimit`` bytes. Callers reuse one buffer for a whole pass.
    static func arguments(of pid: Int32, buffer: inout [UInt8]) -> ProcessArguments {
        if buffer.count < argumentLimit { buffer = [UInt8](repeating: 0, count: argumentLimit) }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        let result = buffer.withUnsafeMutableBytes { bytes in
            sysctl(&mib, 3, bytes.baseAddress, &size, nil, 0)
        }
        if result != 0 {
            // A process that ended after it was listed, or that is a zombie waiting to be reaped, has
            // no arguments. That is "gone", not "could not be read".
            let code = errno
            return code == ESRCH || hasEnded(pid) ? .gone : .unreadable
        }
        return parse(Array(buffer.prefix(size)))
    }

    /// Whether the process no longer exists or is a zombie (it ended and has not been reaped yet).
    static func hasEnded(_ pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size { return info.pbi_status == UInt32(SZOMB) }
        return errno == ESRCH
    }

    /// Parses a `KERN_PROCARGS2` reply: `int argc`, the executable path, padding NULs, then
    /// `argc` NUL-terminated strings (the environment follows and is ignored).
    static func parse(_ reply: [UInt8]) -> ProcessArguments {
        guard reply.count > MemoryLayout<Int32>.size else { return .unreadable }
        let argc = reply.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 0, as: Int32.self)) }
        guard argc >= 0, argc < 4096 else { return .unreadable }
        var index = MemoryLayout<Int32>.size
        let pathStart = index
        while index < reply.count, reply[index] != 0 { index += 1 }
        let executable = String(decoding: reply[pathStart..<index], as: UTF8.self)
        while index < reply.count, reply[index] == 0 { index += 1 }
        var argv: [String] = []
        while argv.count < argc, index < reply.count {
            let start = index
            while index < reply.count, reply[index] != 0 { index += 1 }
            argv.append(String(decoding: reply[start..<index], as: UTF8.self))
            index += 1
        }
        guard argv.count == argc else { return .unreadable }
        return .read(executable: executable, argv: argv)
    }

    /// The text of a NUL-terminated C character buffer.
    static func text(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
