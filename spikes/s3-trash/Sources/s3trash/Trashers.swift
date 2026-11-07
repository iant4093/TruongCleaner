import AppKit
import Dispatch
import Foundation
import Synchronization

/// Outcome of one trash call (single item or batch).
struct MoveResult: Sendable {
    /// Source URL to the URL in the Trash. Missing = not moved.
    var results: [URL: URL] = [:]
    var error: [String: any Sendable]?
    var timedOut = false
    var ms: Double = 0
}

enum Method: String, CaseIterable, Sendable {
    case trashItem
    case recycle

    /// Short prefix so items from different methods never share a name in the Trash.
    var prefix: String { self == .trashItem ? "ti" : "rc" }
}

// MARK: - FileManager.trashItem

func trashWithFileManager(_ url: URL, env: Env) -> MoveResult {
    requireTrashable(url, env: env)
    var result = MoveResult()
    var out: NSURL?
    let start = ContinuousClock.now
    do {
        try FileManager.default.trashItem(at: url, resultingItemURL: &out)
        if let out { result.results[url] = out as URL }
    } catch {
        result.error = describe(error)
    }
    result.ms = milliseconds(ContinuousClock.now - start)
    if let moved = result.results[url] { requireInImageTrash(moved, env: env) }
    return result
}

// MARK: - NSWorkspace.recycle

private enum RawRecycle: Sendable {
    case done([URL: URL], NSError?)
    case timedOut
}

private final class Slot: Sendable {
    let value = Mutex<RawRecycle?>(nil)
}

private final class Gate: Sendable {
    private let continuation: Mutex<CheckedContinuation<RawRecycle, Never>?>
    init(_ continuation: CheckedContinuation<RawRecycle, Never>) {
        self.continuation = Mutex(continuation)
    }
    func resume(_ value: RawRecycle) {
        let taken = continuation.withLock { current -> CheckedContinuation<RawRecycle, Never>? in
            let c = current
            current = nil
            return c
        }
        taken?.resume(returning: value)
    }
}

private func finish(_ raw: RawRecycle, urls: [URL], ms: Double, env: Env) -> MoveResult {
    var result = MoveResult()
    result.ms = ms
    switch raw {
    case .timedOut:
        result.timedOut = true
    case let .done(map, error):
        result.results = map
        if let error { result.error = describe(error) }
    }
    for moved in result.results.values { requireInImageTrash(moved, env: env) }
    return result
}

/// Calls the callback API and blocks the calling thread until it completes or times out.
/// The caller decides which thread that is.
func recycleBlocking(_ urls: [URL], env: Env, timeout: Double) -> MoveResult {
    for url in urls { requireTrashable(url, env: env) }
    let slot = Slot()
    let semaphore = DispatchSemaphore(value: 0)
    let start = ContinuousClock.now
    NSWorkspace.shared.recycle(urls) { map, error in
        slot.value.withLock { $0 = .done(map, error as NSError?) }
        semaphore.signal()
    }
    let timedOut = semaphore.wait(timeout: .now() + timeout) == .timedOut
    let ms = milliseconds(ContinuousClock.now - start)
    let raw = slot.value.withLock { $0 } ?? (timedOut ? .timedOut : .done([:], nil))
    return finish(raw, urls: urls, ms: ms, env: env)
}

/// Calls the callback API from the main actor and suspends (main run loop keeps running).
@MainActor
func recycleOnPumpedMain(_ urls: [URL], env: Env, timeout: Double) async -> MoveResult {
    for url in urls { requireTrashable(url, env: env) }
    let start = ContinuousClock.now
    let raw: RawRecycle = await withCheckedContinuation { continuation in
        let gate = Gate(continuation)
        NSWorkspace.shared.recycle(urls) { map, error in
            gate.resume(.done(map, error as NSError?))
        }
        Task.detached {
            try? await Task.sleep(for: .seconds(timeout))
            gate.resume(.timedOut)
        }
    }
    return finish(raw, urls: urls, ms: milliseconds(ContinuousClock.now - start), env: env)
}

/// Calls the callback API from the main thread and blocks that thread, so the main queue cannot run.
@MainActor
func recycleOnBlockedMain(_ urls: [URL], env: Env, timeout: Double) -> MoveResult {
    recycleBlocking(urls, env: env, timeout: timeout)
}

// MARK: - Dispatch by method

/// Background-thread single-item trash with the chosen API.
func trashOne(_ url: URL, method: Method, env: Env, timeout: Double = 60) -> MoveResult {
    switch method {
    case .trashItem: trashWithFileManager(url, env: env)
    case .recycle: recycleBlocking([url], env: env, timeout: timeout)
    }
}

func onBackgroundQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: body()) }
    }
}
