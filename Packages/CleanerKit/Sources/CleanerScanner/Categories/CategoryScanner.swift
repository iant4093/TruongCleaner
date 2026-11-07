import Foundation

/// Measures how much of the Data volume each ``StorageCategory`` uses (REQ-SYS-03).
///
/// The scanner only reads. It never follows symbolic links, never crosses onto another volume, and
/// reports a folder it may not open as "needs access" instead of counting it as empty.
///
/// How nested roots are kept apart: the home folder is read one level at a time. Each direct child
/// (`Documents`, `Downloads`, `.Trash`, and so on) is walked once as its own category, with no per-folder
/// totals kept. `Library` holds several categories, so it is walked once with folder totals down to the
/// deepest one, and each category's total is subtracted from the Library total. Nothing is read twice
/// and no pair of categories overlaps.
public enum CategoryScanner {
    /// Measures the Data volume's categories.
    ///
    /// Runs off the main actor on up to `min(8, activeProcessorCount)` walker threads. When the calling task
    /// is cancelled the measurement stops within about 100 ms and returns what it has, with `partial == true`.
    ///
    /// - Parameters:
    ///   - home: The user's home folder. Pass a fixture folder in tests.
    ///   - applicationsRoot: The system Applications folder, or `nil` to skip it. `~/Applications` is always
    ///     measured as part of `home`.
    ///   - usersRoot: The folder that holds all home folders, or `nil` to skip other users. The folder that is
    ///     `home` is left out.
    ///   - progress: Called at most about 10 times a second, from a worker thread. Keep it short.
    @concurrent
    public static func measure(
        home: URL,
        applicationsRoot: URL? = URL(filePath: "/Applications", directoryHint: .isDirectory),
        usersRoot: URL? = URL(filePath: "/Users", directoryHint: .isDirectory),
        progress: (@Sendable (CategoryProgress) -> Void)? = nil
    ) async -> CategoryTotals {
        let clock = ContinuousClock()
        let started = clock.now
        var run = CategoryRun(progress: progress)
        if let applicationsRoot { await run.measureFolder(applicationsRoot, as: .applications) }
        await run.measureHome(home)
        if let usersRoot { await run.measureOtherUsers(usersRoot, skipping: home) }
        return run.totals(duration: started.duration(to: clock.now))
    }
}
