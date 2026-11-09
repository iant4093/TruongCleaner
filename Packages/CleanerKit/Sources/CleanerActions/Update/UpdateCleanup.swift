import Darwin
import Foundation

/// What ``UpdateCleanup`` did.
public struct UpdateCleanupReport: Sendable, Equatable {
    /// Old app bundles moved to the Trash.
    public var trashedBundles: [URL] = []
    /// Stale update folders deleted.
    public var removedFolders: [URL] = []
    /// Leftovers it left alone, with the reason.
    public var skipped: [(url: URL, reason: String)] = []

    /// Creates an empty report.
    public init() {}

    /// Compares what was trashed and removed; skip reasons are ignored.
    public static func == (lhs: UpdateCleanupReport, rhs: UpdateCleanupReport) -> Bool {
        lhs.trashedBundles == rhs.trashedBundles && lhs.removedFolders == rhs.removedFolders
    }
}

/// Removes what an update leaves behind. Runs once at launch, off the main actor.
///
/// These are the only deletion sites of the update feature, and both are narrow:
/// - `.TruongCleaner-old-<uuid>.app` next to the running app is moved to the **Trash**, and only
///   if it is a real directory whose `CFBundleIdentifier` is ours.
/// - `TruongCleanerUpdate-<uuid>` folders in the temporary directory are deleted, and only if they
///   are real directories owned by the user and older than `minimumAge` (so a second running copy
///   that is mid-update is not disturbed).
public struct UpdateCleanup: Sendable {
    private let executor: any ItemExecutor

    /// Creates the cleanup. Tests pass a fake executor so nothing touches the real Trash.
    public init(executor: any ItemExecutor = FileManagerExecutor()) {
        self.executor = executor
    }

    /// Looks for leftovers and removes them.
    ///
    /// - Parameters:
    ///   - runningAppFolder: The folder that holds the running app.
    ///   - bundleIdentifier: The running app's identifier; old bundles must match it.
    ///   - temporaryDirectory: Where update folders live.
    ///   - minimumAge: How old an update folder must be before it counts as stale.
    ///   - now: The current time.
    @concurrent
    public func removeLeftovers(
        in runningAppFolder: URL,
        bundleIdentifier: String,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        minimumAge: TimeInterval = 3600,
        now: Date = .now
    ) async -> UpdateCleanupReport {
        var report = UpdateCleanupReport()
        await trashOldBundles(in: runningAppFolder, bundleIdentifier: bundleIdentifier, report: &report)
        removeStaleFolders(in: temporaryDirectory, minimumAge: minimumAge, now: now, report: &report)
        return report
    }

    // MARK: Private

    private func trashOldBundles(
        in folder: URL, bundleIdentifier: String, report: inout UpdateCleanupReport
    ) async {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) else {
            return
        }
        for name in names.sorted() where Self.isOldBundleName(name) {
            let url = folder.appending(path: name, directoryHint: .isDirectory)
            guard Self.isOwnedDirectory(url) else {
                report.skipped.append((url, "not a folder owned by you"))
                continue
            }
            // Unknown means keep: an unreadable bundle or a different identifier is left alone.
            guard Bundle(url: url)?.bundleIdentifier == bundleIdentifier else {
                report.skipped.append((url, "not a TruongCleaner bundle"))
                continue
            }
            do {
                _ = try await executor.moveToTrash(url)
                report.trashedBundles.append(url)
            } catch {
                report.skipped.append((url, error.localizedDescription))
            }
        }
    }

    private func removeStaleFolders(
        in root: URL, minimumAge: TimeInterval, now: Date, report: inout UpdateCleanupReport
    ) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)) else {
            return
        }
        for name in names.sorted() where UpdateWorkspace.isUpdateFolderName(name) {
            let url = root.appending(path: name, directoryHint: .isDirectory)
            guard let age = Self.age(of: url, now: now), age >= minimumAge else {
                report.skipped.append((url, "too new or unreadable"))
                continue
            }
            guard UpdateWorkspace.isOwnedDirectory(url) else {
                report.skipped.append((url, "not a folder owned by you"))
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
                report.removedFolders.append(url)
            } catch {
                report.skipped.append((url, error.localizedDescription))
            }
        }
    }

    /// `.TruongCleaner-old-<uuid>.app`
    static func isOldBundleName(_ name: String) -> Bool {
        let prefix = UpdateInstaller.oldBundlePrefix
        guard name.hasPrefix(prefix), name.hasSuffix(".app") else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(".app".count))) != nil
    }

    private static func isOwnedDirectory(_ url: URL) -> Bool {
        UpdateWorkspace.isOwnedDirectory(url)
    }

    /// Seconds since the folder was last modified, or `nil` if unreadable.
    private static func age(of url: URL, now: Date) -> TimeInterval? {
        var info = stat()
        guard lstat(UpdateWorkspace.unixPath(url), &info) == 0 else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        return now.timeIntervalSince(modified)
    }
}
