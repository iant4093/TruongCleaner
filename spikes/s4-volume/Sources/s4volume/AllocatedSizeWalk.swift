import Darwin
import Foundation
import Synchronization

/// Read-only size of one folder tree using `FileManager.enumerator`, capped by wall-clock time.
/// Allocated bytes (`totalFileAllocatedSize`), symlinks counted but not followed,
/// hard links counted once by (device, inode), and mounts on other devices are not entered.
enum AllocatedSizeWalk {
    private struct DeviceInode: Hashable {
        let device: Int32
        let inode: UInt64
    }

    private final class ErrorLog: Sendable {
        private struct State {
            var count = 0
            var samples: [JSONValue] = []
        }

        private let state = Mutex(State())

        func record(_ url: URL, _ error: any Error) {
            state.withLock {
                $0.count += 1
                if $0.samples.count < 10 {
                    $0.samples.append(["path": .string(url.path), "error": .error(error)])
                }
            }
        }

        var snapshot: (count: Int, samples: [JSONValue]) {
            state.withLock { ($0.count, $0.samples) }
        }
    }

    static func measure(path: String, cap: TimeInterval) -> JSONValue {
        let root = URL(fileURLWithPath: path)
        var rootInfo = stat()
        guard lstat(path, &rootInfo) == 0 else {
            let code = errno
            return ["path": .string(path), "error": .errno(code)]
        }

        let keys: [URLResourceKey] = [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey, .linkCountKey,
        ]
        let errors = ErrorLog()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, error in
                errors.record(url, error)
                return true
            }
        ) else {
            return ["path": .string(path), "error": "FileManager.enumerator returned nil"]
        }

        let started = Date()
        var partial = false
        var bytes: Int64 = 0
        var files = 0
        var directories = 0
        var symlinks = 0
        var hardLinkDuplicates = 0
        var otherDeviceSkipped = 0
        var resourceErrors = 0
        var seenLinks = Set<DeviceInode>()

        while true {
            if Date().timeIntervalSince(started) > cap {
                partial = true
                break
            }
            let finished: Bool = autoreleasepool {
                guard let url = enumerator.nextObject() as? URL else { return true }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                    resourceErrors += 1
                    return false
                }
                if values.isSymbolicLink == true {
                    symlinks += 1
                    return false
                }
                if values.isDirectory == true {
                    directories += 1
                    var info = stat()
                    if lstat(url.path, &info) == 0, info.st_dev != rootInfo.st_dev {
                        otherDeviceSkipped += 1
                        enumerator.skipDescendants()
                    }
                    return false
                }
                files += 1
                if let links = values.linkCount, links > 1 {
                    var info = stat()
                    if lstat(url.path, &info) == 0 {
                        let key = DeviceInode(device: info.st_dev, inode: info.st_ino)
                        if !seenLinks.insert(key).inserted {
                            hardLinkDuplicates += 1
                            return false
                        }
                    }
                }
                bytes += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                return false
            }
            if finished { break }
        }

        let errorSnapshot = errors.snapshot
        return [
            "path": .string(path),
            "api": "FileManager.enumerator + URLResourceValues.totalFileAllocatedSize",
            "allocatedBytes": .int(bytes),
            "human": .string(humanBytes(bytes)),
            "partial": .bool(partial),
            "capSeconds": .double(cap),
            "elapsedSeconds": .double((Date().timeIntervalSince(started) * 100).rounded() / 100),
            "files": .bytes(files),
            "directories": .bytes(directories),
            "symlinksNotFollowed": .bytes(symlinks),
            "hardLinkDuplicatesSkipped": .bytes(hardLinkDuplicates),
            "otherDeviceMountsSkipped": .bytes(otherDeviceSkipped),
            "resourceValueErrors": .bytes(resourceErrors),
            "enumeratorErrors": .bytes(errorSnapshot.count),
            "enumeratorErrorSamples": .array(errorSnapshot.samples),
            "note": errorSnapshot.count > 0 || resourceErrors > 0
                ? "some entries could not be read, so the total is a lower bound"
                : "no read errors",
        ]
    }
}
