import Darwin
import Foundation
import Synchronization

// MARK: - Helpers

private func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

private func rel(_ url: URL, _ env: Env) -> String {
    let prefix = env.vol.path + "/"
    return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
}

/// The Trash URL for a single-item call. NSWorkspace may key its map with a different URL form.
private func singleResult(_ r: MoveResult, _ source: URL) -> URL? {
    r.results[source] ?? (r.results.count == 1 ? r.results.values.first : nil)
}

private func stats(_ values: [Double]) -> [String: any Sendable] {
    guard !values.isEmpty else { return ["count": 0] }
    let sorted = values.sorted()
    let sum = values.reduce(0, +)
    func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
    return [
        "count": values.count,
        "sumMs": round3(sum),
        "meanMs": round3(sum / Double(values.count)),
        "medianMs": pct(0.5),
        "p95Ms": pct(0.95),
        "maxMs": sorted[sorted.count - 1],
    ]
}

private func mean(_ values: ArraySlice<Double>) -> Double {
    values.isEmpty ? 0 : round3(values.reduce(0, +) / Double(values.count))
}

private func moveRecord(
    _ name: String, method: Method, shape: String, source: URL,
    before: Identity?, xattrsBefore: [String]?, result: MoveResult, env: Env
) -> [String: any Sendable] {
    var rec: [String: any Sendable] = [
        "case": name,
        "method": method.rawValue,
        "shape": shape,
        "source": rel(source, env),
        "ms": result.ms,
        "timedOut": result.timedOut,
        "sourceGone": !exists(source),
        "xattrsBefore": xattrsBefore ?? ["<unreadable>"],
        "ok": singleResult(result, source) != nil,
    ]
    if let error = result.error { rec["error"] = error }
    if let b = before {
        rec["inoBefore"] = Int(b.ino)
        rec["resourceIDBefore"] = b.resourceID
        rec["kindBefore"] = b.kind
    }
    if let moved = singleResult(result, source) {
        rec["resultName"] = moved.lastPathComponent
        rec["resultPath"] = rel(moved, env)
        rec["underImageTrash"] = isUnderImageTrash(moved, env: env)
        rec["xattrsAfter"] = xattrNames(moved.path) ?? ["<unreadable>"]
        if let a = identity(moved) {
            rec["inoAfter"] = Int(a.ino)
            rec["resourceIDAfter"] = a.resourceID
            rec["kindAfter"] = a.kind
            if let b = before {
                rec["inoEqual"] = b.ino == a.ino
                rec["resourceIDEqual"] = b.resourceID == a.resourceID
                rec["devEqual"] = b.dev == a.dev
            }
        }
    } else {
        rec["resultPath"] = NSNull()
    }
    return rec
}

// MARK: - Cases (background queue)

private func shapesCase(_ method: Method, env: Env) {
    let p = method.prefix
    let dir = env.work.appending(path: "shapes-\(p)")
    makeDir(dir, env: env)
    let file = dir.appending(path: "\(p)-file.txt")
    makeFile(file)
    let folder = dir.appending(path: "\(p)-folder")
    makeDir(folder, env: env)
    makeFile(folder.appending(path: "a.txt"))
    makeFile(folder.appending(path: "b.txt"))
    let target = dir.appending(path: "\(p)-target.txt")
    makeFile(target)
    let link = dir.appending(path: "\(p)-link")
    makeSymlink(link, to: "\(p)-target.txt")

    for (shape, url) in [("file", file), ("folder", folder), ("symlink", link)] {
        let before = identity(url)
        let xb = xattrNames(url.path)
        let result = trashOne(url, method: method, env: env)
        var rec = moveRecord("trash_shape", method: method, shape: shape, source: url, before: before,
                             xattrsBefore: xb, result: result, env: env)
        if shape == "symlink" {
            rec["targetStillInPlace"] = exists(target)
            if let moved = singleResult(result, url) {
                rec["linkDestinationAfter"] =
                    (try? FileManager.default.destinationOfSymbolicLink(atPath: moved.path)) ?? "<unreadable>"
            }
        }
        Recorder.shared.write(rec)
    }
}

private func collisionCase(_ method: Method, env: Env) {
    let p = method.prefix
    let dir = env.work.appending(path: "collide-\(p)")
    var names: [String] = []
    var errors = 0
    for (sub, size) in [("a", 1), ("b", 2)] {
        let subdir = dir.appending(path: sub)
        makeDir(subdir, env: env)
        let file = subdir.appending(path: "\(p)-same.txt")
        makeFile(file, bytes: size)
        let result = trashOne(file, method: method, env: env)
        if let moved = singleResult(result, file) { names.append(moved.lastPathComponent) } else { errors += 1 }
    }
    Recorder.shared.write([
        "case": "trash_collision",
        "method": method.rawValue,
        "originalName": "\(p)-same.txt",
        "resultNames": names,
        "distinct": Set(names).count == names.count && names.count == 2,
        "errors": errors,
    ])
}

private func listing(_ label: String, env: Env, seen: inout Set<String>) {
    var record = trashSnapshot(label: label, env: env)
    let entries = (record["entries"] as? [String]) ?? []
    record["newEntries"] = entries.filter { !seen.contains($0) }
    seen.formUnion(entries)
    Recorder.shared.write(record)
}

private func moveBackCase(_ method: Method, env: Env) {
    let p = method.prefix
    let dir = env.work.appending(path: "back-\(p)")
    makeDir(dir, env: env)
    let file = dir.appending(path: "\(p)-back.txt")
    makeFile(file)
    let folder = dir.appending(path: "\(p)-backdir")
    makeDir(folder, env: env)
    makeFile(folder.appending(path: "inner.txt"))

    for (shape, url) in [("file", file), ("folder", folder)] {
        let before = identity(url)
        let result = trashOne(url, method: method, env: env)
        guard let moved = singleResult(result, url) else {
            Recorder.shared.write(["case": "move_back", "method": method.rawValue, "shape": shape,
                                   "skipped": "trash call failed"])
            continue
        }
        requireInside(moved, root: env.trash, env: env, what: "move-back source")
        requireInside(url, root: env.work, env: env, what: "move-back destination", mustExist: false)
        var rec: [String: any Sendable] = ["case": "move_back", "method": method.rawValue, "shape": shape]
        do {
            try FileManager.default.moveItem(at: moved, to: url)
            rec["ok"] = true
        } catch {
            rec["ok"] = false
            rec["error"] = describe(error)
        }
        let after = identity(url)
        rec["trashEntryGone"] = !exists(moved)
        rec["restoredAtOriginalPath"] = after != nil
        if let b = before, let a = after {
            rec["inoEqual"] = b.ino == a.ino
            rec["resourceIDEqual"] = b.resourceID == a.resourceID
        }
        Recorder.shared.write(rec)
    }
}

private func folderThroughputCase(_ method: Method, env: Env) {
    let p = method.prefix
    let dir = env.work.appending(path: "tpf-\(p)")
    makeDir(dir, env: env)
    let createStart = ContinuousClock.now
    var folders: [URL] = []
    for i in 0..<100 {
        let folder = dir.appending(path: "\(p)-d\(i)")
        makeDir(folder, env: env)
        for j in 0..<100 { makeFile(folder.appending(path: "f\(j).dat")) }
        folders.append(folder)
    }
    let createSeconds = round3(milliseconds(ContinuousClock.now - createStart) / 1000)

    var times: [Double] = []
    var failures = 0
    var firstError: [String: any Sendable]?
    let start = ContinuousClock.now
    for folder in folders {
        let result = trashOne(folder, method: method, env: env)
        if singleResult(result, folder) != nil {
            times.append(result.ms)
        } else {
            failures += 1
            firstError = firstError ?? result.error ?? ["timedOut": result.timedOut]
            if result.timedOut || failures >= 5 { break }
        }
    }
    let total = milliseconds(ContinuousClock.now - start) / 1000
    var rec: [String: any Sendable] = [
        "case": "throughput_folders",
        "method": method.rawValue,
        "folders": 100,
        "filesPerFolder": 100,
        "totalFiles": 10_000,
        "fixtureCreateSeconds": createSeconds,
        "totalSeconds": round3(total),
        "perFolder": stats(times),
        "failures": failures,
    ]
    if let firstError { rec["firstError"] = firstError }
    Recorder.shared.write(rec)
}

private func smallSetCase(env: Env) {
    enum Variant: String, CaseIterable { case trashItemOneByOne = "ti1", recycleOneByOne = "rc1", recycleBatch = "rcB" }
    for variant in Variant.allCases {
        let dir = env.work.appending(path: "small-\(variant.rawValue)")
        makeDir(dir, env: env)
        var folders: [URL] = []
        for i in 0..<100 {
            let folder = dir.appending(path: "\(variant.rawValue)-d\(i)")
            makeDir(folder, env: env)
            makeFile(folder.appending(path: "f.dat"))
            folders.append(folder)
        }
        var rec: [String: any Sendable] = ["case": "throughput_small_set", "variant": variant.rawValue, "items": 100]
        switch variant {
        case .trashItemOneByOne, .recycleOneByOne:
            let method: Method = variant == .trashItemOneByOne ? .trashItem : .recycle
            var times: [Double] = []
            let start = ContinuousClock.now
            for folder in folders {
                let result = trashOne(folder, method: method, env: env)
                if singleResult(result, folder) != nil { times.append(result.ms) }
            }
            rec["totalSeconds"] = round3(milliseconds(ContinuousClock.now - start) / 1000)
            rec["perItem"] = stats(times)
            rec["failures"] = folders.count - times.count
        case .recycleBatch:
            let result = recycleBlocking(folders, env: env, timeout: 120)
            rec["totalSeconds"] = round3(result.ms / 1000)
            rec["perItemMeanMs"] = round3(result.ms / 100)
            rec["moved"] = result.results.count
            rec["failures"] = folders.count - result.results.count
            rec["timedOut"] = result.timedOut
            if let error = result.error { rec["error"] = error }
        }
        Recorder.shared.write(rec)
    }
}

private func fileThroughputCase(env: Env) {
    let dir = env.work.appending(path: "tpfiles")
    makeDir(dir, env: env)
    let createStart = ContinuousClock.now
    var files: [URL] = []
    for i in 0..<100 {
        let folder = dir.appending(path: "d\(i)")
        makeDir(folder, env: env)
        for j in 0..<100 {
            let file = folder.appending(path: "fl-\(i)-\(j).dat")
            makeFile(file)
            files.append(file)
        }
    }
    let createSeconds = round3(milliseconds(ContinuousClock.now - createStart) / 1000)

    var times: [Double] = []
    var failures = 0
    var firstError: [String: any Sendable]?
    let start = ContinuousClock.now
    for file in files {
        let result = trashWithFileManager(file, env: env)
        if result.results[file] != nil {
            times.append(result.ms)
        } else {
            failures += 1
            firstError = firstError ?? result.error
            if failures >= 5 { break }
        }
    }
    let total = milliseconds(ContinuousClock.now - start) / 1000
    var rec: [String: any Sendable] = [
        "case": "throughput_files",
        "method": Method.trashItem.rawValue,
        "files": 10_000,
        "fixtureCreateSeconds": createSeconds,
        "totalSeconds": round3(total),
        "perFile": stats(times),
        "firstThousandMeanMs": mean(times.prefix(1000)),
        "lastThousandMeanMs": mean(times.suffix(1000)),
        "failures": failures,
    ]
    if let firstError { rec["firstError"] = firstError }
    Recorder.shared.write(rec)
}

private func immutableCase(_ method: Method, env: Env) {
    let p = method.prefix
    let dir = env.work.appending(path: "uchg-\(p)")
    makeDir(dir, env: env)
    let file = dir.appending(path: "\(p)-locked.txt")
    makeFile(file)
    guard chflags(file.path, UInt32(UF_IMMUTABLE)) == 0 else { abortRun("chflags uchg failed") }
    let before = identity(file)
    let xb = xattrNames(file.path)
    let flagsBefore = fileFlags(file.path) ?? -1
    let result = trashOne(file, method: method, env: env, timeout: 20)
    var rec = moveRecord("trash_immutable", method: method, shape: "file-uchg", source: file, before: before,
                         xattrsBefore: xb, result: result, env: env)
    rec["flagsBefore"] = flagsBefore
    rec["flagsOnSourceAfter"] = fileFlags(file.path) ?? -1
    Recorder.shared.write(rec)
    // Always clear the flag so the image contents stay removable.
    if exists(file) { _ = chflags(file.path, 0) }
    for moved in result.results.values { _ = chflags(moved.path, 0) }
}

private func readOnlyParentCase(_ method: Method, env: Env) {
    let p = method.prefix
    let dir = env.work.appending(path: "ro-\(p)")
    let parent = dir.appending(path: "\(p)-ro-parent")
    makeDir(parent, env: env)
    let file = parent.appending(path: "\(p)-inside.txt")
    makeFile(file)
    guard chmod(parent.path, 0o555) == 0 else { abortRun("chmod 555 failed") }
    let before = identity(file)
    let xb = xattrNames(file.path)
    let result = trashOne(file, method: method, env: env, timeout: 20)
    var rec = moveRecord("trash_readonly_parent", method: method, shape: "file-in-555-dir", source: file,
                         before: before, xattrsBefore: xb, result: result, env: env)
    rec["parentMode"] = "0555"
    Recorder.shared.write(rec)
    _ = chmod(parent.path, 0o755)
}

/// Everything that runs on a background queue. Sync on purpose.
func runBackgroundCases(env: Env) {
    var seen = Set<String>()
    for method in Method.allCases {
        log("shapes + collision: \(method.rawValue)")
        shapesCase(method, env: env)
        collisionCase(method, env: env)
        listing("after-\(method.rawValue)", env: env, seen: &seen)
    }
    for method in Method.allCases {
        log("move back: \(method.rawValue)")
        moveBackCase(method, env: env)
    }
    for method in Method.allCases {
        log("immutable + read-only parent: \(method.rawValue)")
        immutableCase(method, env: env)
        readOnlyParentCase(method, env: env)
    }
    log("small set comparison (100 items)")
    smallSetCase(env: env)
    for method in Method.allCases {
        log("throughput, 100 folders x 100 files: \(method.rawValue)")
        folderThroughputCase(method, env: env)
    }
    log("throughput, 10,000 files one by one: trashItem")
    fileThroughputCase(env: env)
}

// MARK: - Cases (main actor)

@MainActor
func runMainActorCases(env: Env) async {
    let dir = env.work.appending(path: "thr")
    makeDir(dir, env: env)

    log("recycle from the main actor, run loop running")
    let pumped = dir.appending(path: "thr-mainpumped.txt")
    makeFile(pumped)
    let before = identity(pumped)
    let pumpedXattrs = xattrNames(pumped.path)
    let pumpedResult = await recycleOnPumpedMain([pumped], env: env, timeout: 30)
    var rec = moveRecord("recycle_threading", method: .recycle, shape: "file", source: pumped, before: before,
                         xattrsBefore: pumpedXattrs, result: pumpedResult, env: env)
    rec["mode"] = "main-actor, main run loop running (async main, no NSApplication)"
    Recorder.shared.write(rec)

    log("recycle from the main thread, main thread blocked 10 s")
    let blocked = dir.appending(path: "thr-mainblocked.txt")
    makeFile(blocked)
    let blockedBefore = identity(blocked)
    let blockedXattrs = xattrNames(blocked.path)
    let blockedResult = recycleOnBlockedMain([blocked], env: env, timeout: 10)
    let goneImmediately = !exists(blocked)
    try? await Task.sleep(for: .seconds(2))
    var rec2 = moveRecord("recycle_threading", method: .recycle, shape: "file", source: blocked,
                          before: blockedBefore, xattrsBefore: blockedXattrs, result: blockedResult, env: env)
    rec2["mode"] = "main thread blocked on a semaphore while waiting for the completion handler"
    rec2["sourceGoneRightAfterTimeout"] = goneImmediately
    rec2["sourceGone2sLater"] = !exists(blocked)
    let trashNames = (try? FileManager.default.contentsOfDirectory(atPath: env.trash.path)) ?? []
    rec2["trashHasEntryWithName"] = trashNames.contains { $0.hasPrefix("thr-mainblocked") }
    Recorder.shared.write(rec2)

    // Call from a background queue while the main thread is blocked, so no main run loop runs.
    for method in Method.allCases {
        log("\(method.rawValue) from a background queue while the main thread is blocked")
        let file = dir.appending(path: "\(method.prefix)-thr-bgmainblocked.txt")
        makeFile(file)
        let fileBefore = identity(file)
        let fileXattrs = xattrNames(file.path)
        let result = runOnBackgroundWhileCallerBlocks(file, method: method, env: env)
        var rec3 = moveRecord("recycle_threading", method: method, shape: "file", source: file,
                              before: fileBefore, xattrsBefore: fileXattrs, result: result, env: env)
        rec3["mode"] = "background queue call while the main thread is blocked (no main run loop)"
        Recorder.shared.write(rec3)
    }
}

private final class ResultSlot: Sendable {
    let value = Mutex<MoveResult?>(nil)
}

/// Synchronous on purpose: blocks the calling thread (the main thread, when called from the main actor)
/// while a background queue makes the trash call, so no main run loop can run. The call is bounded by its own timeout.
private func runOnBackgroundWhileCallerBlocks(_ file: URL, method: Method, env: Env) -> MoveResult {
    let slot = ResultSlot()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        slot.value.withLock { $0 = trashOne(file, method: method, env: env, timeout: 10) }
        done.signal()
    }
    done.wait()
    return slot.value.withLock { $0 } ?? MoveResult(timedOut: true)
}

/// Final check of the Trash's .DS_Store: which trashed names have Put Back records.
/// Waits briefly because the file is written lazily after the trash calls return.
func putBackSummary(env: Env) async {
    try? await Task.sleep(for: .seconds(3))
    let url = env.trash.appending(path: ".DS_Store")
    guard let records = putBackRecords(in: url) else {
        Recorder.shared.write(["case": "putback_summary", "readable": false])
        return
    }
    func group(_ names: [String]) -> String { "\(names.filter { records.names.contains($0) }.count)/\(names.count)" }
    let groups: [String: String] = [
        "trashItem files (10000)": group((0..<100).flatMap { i in (0..<100).map { "fl-\(i)-\($0).dat" } }),
        "trashItem folders (100)": group((0..<100).map { "ti-d\($0)" }),
        "recycle folders one-by-one (100)": group((0..<100).map { "rc-d\($0)" }),
        "small set trashItem (100)": group((0..<100).map { "ti1-d\($0)" }),
        "small set recycle one-by-one (100)": group((0..<100).map { "rc1-d\($0)" }),
        "small set recycle batch (100)": group((0..<100).map { "rcB-d\($0)" }),
        "shapes trashItem (file, folder, symlink)": group(["ti-file.txt", "ti-folder", "ti-link"]),
        "shapes recycle (file, folder, symlink)": group(["rc-file.txt", "rc-folder", "rc-link"]),
        "collision names": group(["ti-same.txt", "rc-same.txt"]),
        "recycle on main thread": group(["thr-mainpumped.txt", "thr-mainblocked.txt"]),
    ]
    Recorder.shared.write([
        "case": "putback_summary",
        "readable": true,
        "dsStoreBytes": records.bytes,
        "distinctOriginalNames": records.names.count,
        "distinctOriginalFolders": records.folders.count,
        "matchedByGroup": groups,
    ])
}
