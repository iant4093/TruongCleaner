import CleanerCore
import CleanerTestSupport
import Darwin
import Foundation
import Synchronization
import Testing

@testable import CleanerScanner

/// Scanner review #3: a FIFO where a plist should be must not block the reader.
struct SmallPlistTests {
    /// Runs `work` on a dispatch thread and waits at most `limit` for it. Returns nil on a timeout.
    /// The thread is not cancellable, so a hang costs one thread, not the test run.
    private func finishes<T: Sendable>(within limit: Duration, _ work: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let resumed = Atomic<Bool>(false)
            let resume: @Sendable (T?) -> Void = { value in
                if resumed.compareExchange(expected: false, desired: true, ordering: .sequentiallyConsistent).exchanged {
                    continuation.resume(returning: value)
                }
            }
            DispatchQueue.global(qos: .userInitiated).async { resume(work()) }
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds(of: limit)))) {
                resume(nil)
            }
        }
    }

    /// Like `finishes`, for async work. The work runs in a task of its own that is left behind on a timeout,
    /// because a task stuck in a system call cannot be cancelled and a task group would wait for it.
    private func finishesAsync<T: Sendable>(within limit: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let resumed = Atomic<Bool>(false)
            let resume: @Sendable (T?) -> Void = { value in
                if resumed.compareExchange(expected: false, desired: true, ordering: .sequentiallyConsistent).exchanged {
                    continuation.resume(returning: value)
                }
            }
            Task.detached { resume(await work()) }
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds(of: limit)))) {
                resume(nil)
            }
        }
    }

    /// Opens the FIFO for writing so a reader stuck in `open` (the bug) is released and its thread ends.
    private func releaseReader(of fifo: URL) {
        let fd = open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        if fd >= 0 { close(fd) }
    }

    @Test func aFifoIsRefusedWithoutBlocking() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let fifo = try tree.addFIFO("Info.plist")

        let failure = await finishes(within: timingBudget(.seconds(5))) { () -> SmallPlist.Failure? in
            if case .failure(let failure) = SmallPlist.read(at: fifo) { return failure }
            return nil
        }
        releaseReader(of: fifo)

        let outcome = try #require(failure, "SmallPlist.read blocked on a FIFO")
        #expect(outcome == .notAFile)
    }

    @Test func aRegularPlistStillReadsAfterTheNonBlockingOpen() throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let url = try tree.addFile("good.plist", size: 0)
        try PropertyListSerialization.data(fromPropertyList: ["Label": "x", "N": 3], format: .xml, options: 0).write(to: url)

        guard case .success(let values) = SmallPlist.read(at: url) else {
            Issue.record("a regular plist did not read")
            return
        }
        #expect(values["Label"] as? String == "x")
        #expect(values["N"] as? Int == 3)
    }

    @Test func anAppWithAFifoInfoPlistDoesNotStopTheInventory() async throws {
        let harness = try AppsHarness()
        defer { harness.remove() }
        try harness.addApp(file: "Good", bundleID: "com.example.Good")
        _ = try harness.tree.addDirectory("Applications/Bad.app/Contents")
        let fifo = try harness.tree.addFIFO("Applications/Bad.app/Contents/Info.plist")
        let folders = harness.folders

        let inventory = await finishesAsync(within: timingBudget(.seconds(10))) {
            await AppInventory.scan(folders: folders)
        }
        releaseReader(of: fifo)

        let found = try #require(inventory, "AppInventory.scan blocked on a FIFO Info.plist")
        #expect(found.apps.count == 2)
        #expect(found.isComplete == false)
    }
}
