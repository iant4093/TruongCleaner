import Darwin
import Foundation

/// Item 8 of the brief: can a normal user process look at these system folders?
/// Everything here is `lstat`, `getattrlist`, `open(O_RDONLY)` and `readdir`. Nothing is written.
enum PathProbe {
    static let paths = [
        "/System/Volumes/Data/.Spotlight-V100",
        "/System/Library/AssetsV2",
        "/private/var/vm",
        "/Library/Updates",
        "/private/var/db/oah",
    ]

    /// Directory entries listed (name and allocated size) when a folder can be read.
    private static let listLimit = 50

    static func probe(path: String) -> JSONValue {
        var out: [String: JSONValue] = ["path": .string(path)]

        // lstat (never follows a symlink)
        var info = stat()
        var statOK = false
        if lstat(path, &info) == 0 {
            statOK = true
            out["lstat"] = [
                "api": "lstat(2)",
                "type": .string(fileType(info.st_mode)),
                "uid": .int(Int64(info.st_uid)),
                "mode": .string(String(info.st_mode & 0o7777, radix: 8)),
                "st_flags": .int(Int64(info.st_flags)),
                "st_size": .int(Int64(info.st_size)),
                "allocatedBytes (st_blocks * 512)": .int(Int64(info.st_blocks) * 512),
                "note": "for a directory these are the directory node only, not its contents",
            ]
        } else {
            let code = errno
            out["lstat"] = ["api": "lstat(2)", "error": .errno(code)]
        }

        // getattrlist
        out["getattrlist"] = objectType(path: path)

        // open + readdir
        out["list"] = list(path: path)

        let listable = out["list"].flatMap { value -> Bool? in
            if case .object(let object) = value, case .bool(let flag)? = object["canList"] { return flag }
            return nil
        } ?? false
        out["readableByUser"] = [
            "lstatWorks": .bool(statOK),
            "contentsListable": .bool(listable),
        ]
        return .object(out)
    }

    private static func fileType(_ mode: mode_t) -> String {
        switch mode & S_IFMT {
        case S_IFDIR: "directory"
        case S_IFREG: "file"
        case S_IFLNK: "symlink"
        default: "other"
        }
    }

    private static func objectType(path: String) -> JSONValue {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_OBJTYPE)
        var buffer = [UInt8](repeating: 0, count: 16)
        let size = buffer.count
        guard getattrlist(path, &list, &buffer, size, UInt32(FSOPT_NOFOLLOW)) == 0 else {
            let code = errno
            return ["api": "getattrlist(ATTR_CMN_OBJTYPE, FSOPT_NOFOLLOW)", "error": .errno(code)]
        }
        let objectType = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        return [
            "api": "getattrlist(ATTR_CMN_OBJTYPE, FSOPT_NOFOLLOW)",
            "fsobj_type": .int(Int64(objectType)),
            "note": "1 = VREG, 2 = VDIR, 5 = VLNK",
        ]
    }

    private static func list(path: String) -> JSONValue {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            return ["api": "open(O_RDONLY|O_DIRECTORY|O_NOFOLLOW)", "canList": false, "error": .errno(code)]
        }
        guard let directory = fdopendir(descriptor) else {
            let code = errno
            close(descriptor)
            return ["api": "fdopendir(3)", "canList": false, "error": .errno(code)]
        }
        defer { closedir(directory) }

        var entries: [JSONValue] = []
        var count = 0
        var readError: JSONValue = .null
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { readError = .errno(errno) }
                break
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            count += 1
            if entries.count < listLimit {
                var child = stat()
                if fstatat(descriptor, name, &child, AT_SYMLINK_NOFOLLOW) == 0 {
                    entries.append([
                        "name": .string(name),
                        "type": .string(fileType(child.st_mode)),
                        "allocatedBytes": .int(Int64(child.st_blocks) * 512),
                    ])
                } else {
                    entries.append(["name": .string(name), "error": .errno(errno)])
                }
            }
        }
        return [
            "api": "open + fdopendir + readdir",
            "canList": true,
            "entryCount": .bytes(count),
            "entriesShown": .bytes(entries.count),
            "entries": .array(entries),
            "readdirError": readError,
        ]
    }
}
