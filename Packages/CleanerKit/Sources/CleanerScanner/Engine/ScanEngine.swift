import CleanerCore
import Foundation

/// Turns rules into findings: expands each rule's roots, walks them with `BulkWalker`, and runs
/// `Matcher.evaluate` on what the walk found.
///
/// The engine only reads. It never deletes, and everything it does runs off the main actor.
public actor ScanEngine {
    /// Creates an engine.
    public init() {}

    /// Starts a scan and returns its events.
    ///
    /// Events arrive as: `.ruleStarted` and `.ruleFinished` for each rule (finished results in request order),
    /// throttled `.progress`, and `.finished` last. The stream ends after `.finished`.
    ///
    /// Cancelling the task that reads the stream stops the walks within about 100 ms. A consumer that
    /// has stopped reading no longer receives events, so it does not see the final `.finished`.
    ///
    /// - Parameter request: Rules, environment and parallelism.
    public func scan(_ request: ScanRequest) -> AsyncStream<ScanEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ScanEvent.self, bufferingPolicy: .unbounded)
        let task = Task.detached(priority: .userInitiated) {
            let report = await ScanRun.execute(request) { continuation.yield($0) }
            continuation.yield(.finished(report))
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
