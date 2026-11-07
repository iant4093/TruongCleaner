import Darwin
import Foundation
import Synchronization

// MARK: - Recorder (JSON lines)

/// Appends one JSON object per line to results.jsonl.
final class Recorder: Sendable {
    static let shared = Recorder()
    private let handle = Mutex<FileHandle?>(nil)

    func open(path: String) {
        FileManager.default.createFile(atPath: path, contents: Data())
        handle.withLock { $0 = FileHandle(forWritingAtPath: path) }
    }

    func write(_ fields: [String: any Sendable]) {
        let object: [String: Any] = fields
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else {
            FileHandle.standardError.write(Data("unserializable record: \(fields.keys.sorted())\n".utf8))
            return
        }
        data.append(0x0A)
        handle.withLock { try? $0?.write(contentsOf: data) }
    }
}

func milliseconds(_ d: Duration) -> Double {
    let c = d.components
    let ms = Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    return (ms * 1000).rounded() / 1000
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[s3] \(message)\n".utf8))
}

/// Writes an abort record, tells stderr, exits. run.sh's trap then detaches the image.
func abortRun(_ message: String) -> Never {
    Recorder.shared.write(["case": "abort", "message": message])
    FileHandle.standardError.write(Data("ABORT: \(message)\n".utf8))
    exit(3)
}

// MARK: - Environment and path guards

struct Env: Sendable {
    /// Real path of the mounted image's mount point.
    let vol: URL
    /// `<vol>/.Trashes/<uid>`, the only legal destination for trashed items.
    let trash: URL
    /// `<vol>/work`, the only place a trash call may be aimed at.
    let work: URL
    let uid: uid_t
    let device: dev_t
}

func realPath(_ path: String) -> String? {
    guard let p = realpath(path, nil) else { return nil }
    defer { free(p) }
    return String(cString: p)
}

private func components(_ path: String) -> [String] {
    URL(fileURLWithPath: path).standardizedFileURL.pathComponents
}

private func isStrictlyInside(_ child: [String], _ parent: [String]) -> Bool {
    child.count > parent.count && Array(child.prefix(parent.count)) == parent
}

private func cString<T>(_ tuple: T) -> String {
    withUnsafePointer(to: tuple) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
    }
}

/// Validates that `arg` is a real, separate APFS mount made from a disk device,
/// then builds the Env. Aborts on anything else.
func makeEnv(mountArgument arg: String) -> Env {
    guard let vol = realPath(arg) else { abortRun("mount point does not exist: \(arg)") }
    var sfs = statfs()
    guard statfs(vol, &sfs) == 0 else { abortRun("statfs failed for \(vol)") }
    let fsType = cString(sfs.f_fstypename)
    let mountOn = cString(sfs.f_mntonname)
    let mountFrom = cString(sfs.f_mntfromname)
    guard fsType == "apfs" else { abortRun("not APFS: \(fsType)") }
    guard mountFrom.hasPrefix("/dev/disk") else { abortRun("not a disk device: \(mountFrom)") }
    guard realPath(mountOn) == vol else { abortRun("path is not a mount point: \(vol) vs \(mountOn)") }

    var own = stat()
    var parent = stat()
    guard stat(vol, &own) == 0,
          stat(URL(fileURLWithPath: vol).deletingLastPathComponent().path, &parent) == 0
    else { abortRun("stat failed") }
    guard own.st_dev != parent.st_dev else { abortRun("mount point shares a device with its parent") }

    let uid = getuid()
    let volURL = URL(fileURLWithPath: vol)
    let env = Env(
        vol: volURL,
        trash: volURL.appending(path: ".Trashes").appending(path: String(uid)),
        work: volURL.appending(path: "work"),
        uid: uid,
        device: own.st_dev
    )
    Recorder.shared.write([
        "case": "env",
        "mountPoint": vol,
        "mountedFrom": mountFrom,
        "fsType": fsType,
        "mountFlags": Int(sfs.f_flags),
        "ignoreOwnership": (sfs.f_flags & UInt32(MNT_IGNORE_OWNERSHIP)) != 0,
        "uid": Int(uid),
        "expectedTrash": env.trash.path,
        "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
    ])
    return env
}

/// Fail-closed check. `url` must be strictly inside `root` once its PARENT is
/// resolved (the item itself may be a symlink and is never resolved), and
/// must live on the image's device.
func requireInside(_ url: URL, root: URL, env: Env, what: String, mustExist: Bool = true) {
    let name = url.lastPathComponent
    guard !name.isEmpty, name != ".", name != ".." else { abortRun("\(what): bad name \(url.path)") }
    guard let parent = realPath(url.deletingLastPathComponent().path) else {
        abortRun("\(what): parent unresolvable \(url.path)")
    }
    let full = components(parent) + [name]
    guard isStrictlyInside(full, components(root.path)) else {
        abortRun("\(what): \(full.joined(separator: "/")) is outside \(root.path)")
    }
    var st = stat()
    if lstat(url.path, &st) != 0 {
        if mustExist { abortRun("\(what): lstat failed \(url.path)") }
        var parentStat = stat()
        guard stat(url.deletingLastPathComponent().path, &parentStat) == 0, parentStat.st_dev == env.device else {
            abortRun("\(what): parent on wrong device \(url.path)")
        }
        return
    }
    guard st.st_dev == env.device else { abortRun("\(what): wrong device \(url.path)") }
}

/// Call before every trash call.
func requireTrashable(_ url: URL, env: Env) {
    requireInside(url, root: env.work, env: env, what: "trash source")
}

/// Call on every URL a trash API returns. Aborts the run if the item is not in the image's Trash.
func requireInImageTrash(_ url: URL, env: Env) {
    let comps = components(realPath(url.deletingLastPathComponent().path) ?? url.deletingLastPathComponent().path)
        + [url.lastPathComponent]
    guard isStrictlyInside(comps, components(env.trash.path)) else {
        abortRun("trash result escaped the image: \(url.path)")
    }
}

func isUnderImageTrash(_ url: URL, env: Env) -> Bool {
    let parent = realPath(url.deletingLastPathComponent().path) ?? url.deletingLastPathComponent().path
    return isStrictlyInside(components(parent) + [url.lastPathComponent], components(env.trash.path))
}

// MARK: - Fixtures

func makeDir(_ url: URL, env: Env) {
    guard isStrictlyInside(components(url.path), components(env.work.path)) else {
        abortRun("mkdir outside work: \(url.path)")
    }
    do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) } catch {
        abortRun("mkdir failed \(url.path): \(error)")
    }
}

func makeFile(_ url: URL, bytes: Int = 16) {
    guard FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x41, count: bytes)) else {
        abortRun("createFile failed \(url.path)")
    }
}

func makeSymlink(_ link: URL, to target: String) {
    do { try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target) } catch {
        abortRun("symlink failed \(link.path): \(error)")
    }
}

// MARK: - Identity, xattrs, listings

struct Identity: Sendable, Equatable {
    var ino: UInt64
    var dev: Int
    /// Description of URLResourceKey.fileResourceIdentifierKey.
    var resourceID: String
    var kind: String
}

func identity(_ url: URL) -> Identity? {
    var st = stat()
    guard lstat(url.path, &st) == 0 else { return nil }
    let kind: String
    switch st.st_mode & S_IFMT {
    case S_IFREG: kind = "file"
    case S_IFDIR: kind = "dir"
    case S_IFLNK: kind = "symlink"
    default: kind = "other"
    }
    let rid = (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
    return Identity(
        ino: UInt64(st.st_ino),
        dev: Int(st.st_dev),
        resourceID: rid.map { String(describing: $0) } ?? "nil",
        kind: kind
    )
}

func exists(_ url: URL) -> Bool {
    var st = stat()
    return lstat(url.path, &st) == 0
}

func xattrNames(_ path: String) -> [String]? {
    let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
    if size < 0 { return nil }
    if size == 0 { return [] }
    var buffer = [UInt8](repeating: 0, count: size)
    let got = buffer.withUnsafeMutableBytes {
        listxattr(path, $0.baseAddress?.assumingMemoryBound(to: CChar.self), size, XATTR_NOFOLLOW)
    }
    if got < 0 { return nil }
    return buffer.prefix(got).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
}

func fileFlags(_ path: String) -> Int? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    return Int(st.st_flags)
}

/// Reads a .DS_Store and returns the original names (ptbN) and original folders (ptbL) Finder-style
/// Put Back records hold. Values are `ustr`: 4-byte big-endian length, then UTF-16BE.
func putBackRecords(in url: URL) -> (names: Set<String>, folders: Set<String>, bytes: Int)? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let b = [UInt8](data)
    var names = Set<String>()
    var folders = Set<String>()
    var i = 0
    while i + 12 <= b.count {
        let isCode = b[i] == 0x70 && b[i + 1] == 0x74 && b[i + 2] == 0x62 && (b[i + 3] == 0x4C || b[i + 3] == 0x4E)
        let isUstr = b[i + 4] == 0x75 && b[i + 5] == 0x73 && b[i + 6] == 0x74 && b[i + 7] == 0x72
        if isCode, isUstr {
            let n = Int(UInt32(b[i + 8]) << 24 | UInt32(b[i + 9]) << 16 | UInt32(b[i + 10]) << 8 | UInt32(b[i + 11]))
            if n > 0, n < 4096, i + 12 + 2 * n <= b.count,
               let s = String(data: Data(b[(i + 12)..<(i + 12 + 2 * n)]), encoding: .utf16BigEndian) {
                if b[i + 3] == 0x4E { names.insert(s) } else { folders.insert(s) }
            }
            i += 12
        } else {
            i += 1
        }
    }
    return (names, folders, b.count)
}

/// Reads a .DS_Store and counts the Put Back record codes Finder writes.
func putBackMarkers(in url: URL) -> [String: any Sendable] {
    guard let data = try? Data(contentsOf: url) else { return ["readable": false] }
    func count(_ code: String) -> Int {
        let needle = Array(code.utf8)
        let bytes = [UInt8](data)
        guard bytes.count >= needle.count else { return 0 }
        var n = 0
        for i in 0...(bytes.count - needle.count) where bytes[i] == needle[0] && Array(bytes[i..<(i + needle.count)]) == needle {
            n += 1
        }
        return n
    }
    return ["readable": true, "bytes": data.count, "ptbL": count("ptbL"), "ptbN": count("ptbN")]
}

/// Snapshot of the image's Trash folder: entry names (hidden included), xattrs of the folder and of each entry.
func trashSnapshot(label: String, env: Env, limit: Int = 60) -> [String: any Sendable] {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: env.trash.path) else {
        return ["case": "trash_listing", "label": label, "readable": false]
    }
    let sorted = names.sorted()
    var entryXattrs: [String: [String]] = [:]
    for name in sorted.prefix(limit) {
        entryXattrs[name] = xattrNames(env.trash.appending(path: name).path) ?? ["<unreadable>"]
    }
    var record: [String: any Sendable] = [
        "case": "trash_listing",
        "label": label,
        "readable": true,
        "entryCount": sorted.count,
        "entries": Array(sorted.prefix(limit)),
        "hiddenEntries": sorted.filter { $0.hasPrefix(".") },
        "trashFolderXattrs": xattrNames(env.trash.path) ?? ["<unreadable>"],
        "entryXattrs": entryXattrs,
    ]
    let dsStore = env.trash.appending(path: ".DS_Store")
    if sorted.contains(".DS_Store") { record["dsStore"] = putBackMarkers(in: dsStore) }
    return record
}

// MARK: - Errors

func describe(_ error: any Error) -> [String: any Sendable] {
    let ns = error as NSError
    var out: [String: any Sendable] = [
        "domain": ns.domain,
        "code": ns.code,
        "message": ns.localizedDescription,
    ]
    if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
        out["underlyingDomain"] = under.domain
        out["underlyingCode"] = under.code
    }
    if let path = ns.userInfo[NSFilePathErrorKey] as? String { out["errorPath"] = path }
    return out
}
