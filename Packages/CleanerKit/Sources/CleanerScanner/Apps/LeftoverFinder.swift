import CleanerCore
import Darwin
import Foundation

/// A leftover file or folder in `~/Library` that the user may remove along with the app.
public struct Leftover: Sendable, Identifiable {
    /// The item as the scan saw it. Its rule is `apps.uninstall`.
    public let finding: Finding
    /// The folder it lies in.
    public let place: LeftoverPlace
    /// `.safe` is selected by default; `.review` is not.
    public let tier: Tier
    /// Why it belongs to the app.
    public let evidence: LeftoverEvidence
    /// True when macOS refused some folders inside, so the real size is larger.
    public let sizeIsAtLeast: Bool

    /// Unique per item.
    public var id: UUID { finding.id }
    /// The file or folder name.
    public var name: String { finding.url.lastPathComponent }
}

/// An item in `/Library` that belongs to the app. Shown only: it needs an administrator and is never deleted.
public struct SystemLeftover: Sendable, Identifiable {
    /// Where it is.
    public let url: URL
    /// The folder it lies in.
    public let place: LeftoverPlace
    /// Why it belongs to the app.
    public let evidence: LeftoverEvidence
    /// Allocated bytes, or nil when it could not be measured.
    public let allocatedBytes: Int64?

    /// The path.
    public var id: String { url.path(percentEncoded: false) }
}

/// A searched folder that could not be read in full.
public struct UnreadablePlace: Sendable, Hashable {
    /// The folder.
    public let place: LeftoverPlace
    /// True when macOS refused access, which Full Disk Access may fix.
    public let needsAccess: Bool
}

/// Everything the uninstall screen shows for one app.
public struct UninstallReport: Sendable {
    /// The app.
    public let app: AppFacts
    /// The rule and its folders. Pass `setup.rule` and `setup.expandedRoots` to `CleanPlan`.
    public let setup: UninstallRule.Setup
    /// The `.app` bundle as a finding.
    public let bundle: Finding
    /// True when macOS refused some folders inside the bundle.
    public let bundleSizeIsAtLeast: Bool
    /// Leftovers in `~/Library`.
    public let leftovers: [Leftover]
    /// Items in `/Library` (information only).
    public let systemItems: [SystemLeftover]
    /// Searched `~/Library` folders that could not be read in full.
    public let unreadablePlaces: [UnreadablePlace]
    /// Matches that were left out because they could not be measured.
    public let unmeasuredCount: Int
    /// A sentence to show when matching was limited, or nil.
    public let notice: String?
}

/// Finds the files an app left behind (`docs/UNINSTALLER.md` §2, §3).
///
/// Reads the searched folders (direct children only), the container and launch job plists, and sizes
/// the matches. It never follows a symbolic link, never reads outside the listed folders, and deletes
/// nothing. The matching itself is `LeftoverMatcher`.
public enum LeftoverFinder {
    /// Most names read from inside one candidate folder when checking for other apps' IDs.
    private static let childNameLimit = 5_000

    /// Finds the leftovers of `app`.
    ///
    /// - Parameters:
    ///   - app: The app to remove.
    ///   - inventory: Every installed app (see `AppInventory.scan`).
    ///   - isRunning: Whether the app is running; nil when unknown.
    ///   - context: This Mac's folders. Tests pass fixture folders.
    /// - Returns: The report, or the reason the app cannot be uninstalled.
    @concurrent
    public static func find(
        for app: AppFacts, inventory: InstalledApps, isRunning: Bool?, context: UninstallContext
    ) async -> Result<UninstallReport, UninstallRefusal> {
        let setup: UninstallRule.Setup
        switch UninstallRule.make(for: app, isRunning: isRunning, context: context) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let made): setup = made
        }
        guard let bundle = await measureDirectory(app.url) else { return .failure(.unreadable) }

        // 1. Read the folders.
        var listings: [LeftoverPlace: [LeftoverEntry]] = [:]
        var byName: [LeftoverPlace: [String: FolderEntry]] = [:]
        var unreadable: [UnreadablePlace] = []
        for place in LeftoverPlace.all {
            if Task.isCancelled { return .failure(.unreadable) }
            let folder = folderURL(for: place, context: context)
            switch FolderReader.read(folder) {
            case .failure(let failure):
                if !failure.isMissing, place.scope == .user {
                    unreadable.append(UnreadablePlace(place: place, needsAccess: failure.isDenied))
                }
            case .success(let listing):
                if !listing.isComplete, place.scope == .user {
                    unreadable.append(UnreadablePlace(place: place, needsAccess: listing.denied > 0))
                }
                let (found, index) = readEntries(of: listing, in: place)
                listings[place] = found
                byName[place] = index
            }
        }

        // 2. Match.
        let matches = LeftoverMatcher.match(app: app, inventory: inventory, listings: listings) { place, name in
            guard let entry = byName[place]?[name], case .success(let inside) = FolderReader.read(entry.url),
                inside.isComplete, inside.entries.count <= childNameLimit
            else { return nil }
            return inside.entries.compactMap(\.name)
        }

        // 3. Measure.
        var leftovers: [Leftover] = []
        var system: [SystemLeftover] = []
        var unmeasured = 0
        for candidate in matches.candidates {
            if Task.isCancelled { return .failure(.unreadable) }
            guard let entry = byName[candidate.place]?[candidate.name] else { continue }
            if candidate.place.scope == .system {
                let measured = await measure(entry)
                system.append(
                    SystemLeftover(
                        url: entry.url, place: candidate.place, evidence: candidate.evidence,
                        allocatedBytes: measured?.allocatedBytes))
                continue
            }
            guard let measured = await measure(entry, lookForDiskImages: candidate.tier == .safe) else {
                unmeasured += 1
                continue
            }
            let reviewed = reviewedAfterMeasuring(candidate, entry: entry, measured: measured)
            leftovers.append(
                Leftover(
                    finding: measured.finding(for: entry.url),
                    place: candidate.place, tier: reviewed.tier, evidence: reviewed.evidence,
                    sizeIsAtLeast: measured.isPartial))
        }

        return .success(
            UninstallReport(
                app: app, setup: setup, bundle: bundle.finding(for: app.url), bundleSizeIsAtLeast: bundle.isPartial,
                leftovers: leftovers, systemItems: system, unreadablePlaces: unreadable,
                unmeasuredCount: unmeasured, notice: matches.notice))
    }

    // MARK: Folders

    private static func folderURL(for place: LeftoverPlace, context: UninstallContext) -> URL {
        let library = place.scope == .user
            ? context.home.appending(path: "Library", directoryHint: .isDirectory)
            : context.systemLibrary
        return place.folder.components.reduce(library) { $0.appending(path: $1, directoryHint: .isDirectory) }
    }

    /// The matcher's view of a listing, and the same entries by name. Links and special files are left out:
    /// a link is never followed and never offered. Plists that decide a match are read here.
    private static func readEntries(
        of listing: FolderListing, in place: LeftoverPlace
    ) -> ([LeftoverEntry], [String: FolderEntry]) {
        var entries: [LeftoverEntry] = []
        var index: [String: FolderEntry] = [:]
        for entry in listing.entries {
            guard let name = entry.name, entry.kind == .directory || entry.kind == .file else { continue }
            var item = LeftoverEntry(name: name, isDirectory: entry.kind == .directory)
            if place.folder == .containers, entry.kind == .directory, isUUID(name) {
                // Only containers named by a UUID need their record. Reading a container named by a
                // bundle ID could ask the user to allow access to that app's data for no gain.
                item.metadataIdentifier = containerIdentifier(at: entry.url)
            } else if place.folder.holdsLaunchJobs, entry.kind == .file {
                item.launchJob = launchJob(at: entry.url)
            }
            entries.append(item)
            index[name] = entry
        }
        return (entries, index)
    }

    private static func isUUID(_ name: String) -> Bool {
        UUID(uuidString: name) != nil
    }

    private static func containerIdentifier(at container: URL) -> String? {
        let record = container.appending(path: ".com.apple.containermanagerd.metadata.plist")
        guard case .success(let plist) = SmallPlist.read(at: record) else { return nil }
        return plist["MCMMetadataIdentifier"] as? String
    }

    private static func launchJob(at plist: URL) -> LaunchJob? {
        guard case .success(let values) = SmallPlist.read(at: plist) else { return nil }
        var programs: [String] = []
        if let program = values["Program"] as? String { programs.append(program) }
        if let arguments = values["ProgramArguments"] as? [Any], let first = arguments.first as? String {
            programs.append(first)
        }
        return LaunchJob(label: values["Label"] as? String, programs: programs)
    }

    // MARK: Measuring

    /// Applies what was measured inside a user-scope folder to its candidate (`LeftoverMatcher.reviewed`).
    ///
    /// The matcher judged the folder from its direct children's names. Docker's `Docker.raw`, for one, sits
    /// at `Data/vms/0/data/Docker.raw`, so only the measurement can see it. The check reads these facts:
    /// - the allocated size of the whole folder;
    /// - whether `Data/Documents` holds anything (read without following links; nil when it cannot be read);
    /// - whether one of the largest files in it is a virtual machine or disk image. The walk keeps the five
    ///   largest files anyway, so this costs no per-file allocation. It can say "yes", never "no", so a small
    ///   image outside the top five is left to the size check.
    ///
    /// A partial measurement, or an unreadable `Data/Documents`, makes the folder `.review`. A candidate is
    /// never made less strict.
    private static func reviewedAfterMeasuring(
        _ candidate: LeftoverCandidate, entry: FolderEntry, measured: Measured
    ) -> LeftoverCandidate {
        guard candidate.tier == .safe, candidate.place.scope == .user, entry.kind == .directory else {
            return candidate
        }
        let documents = hasDocuments(in: entry)
        let contents = LeftoverContents(
            allocatedBytes: measured.allocatedBytes, hasDocuments: documents,
            hasDiskImages: measured.holdsDiskImage ? true : nil)
        return LeftoverMatcher.reviewed(
            candidate, contents: contents, isComplete: !measured.isPartial && documents != nil)
    }

    /// Whether `<container>/Data/Documents` lists at least one entry. Nothing is followed: `Data` and
    /// `Documents` must be real folders. A missing folder is false; a folder that cannot be read in full
    /// (and shows nothing) is nil.
    private static func hasDocuments(in container: FolderEntry) -> Bool? {
        let data = container.url.appending(path: "Data", directoryHint: .isDirectory)
        let listing: FolderListing
        switch FolderReader.read(data) {
        case .failure(let failure): return failure.isMissing ? false : nil
        case .success(let read): listing = read
        }
        guard let documents = listing.entries.first(where: { $0.name == "Documents" }) else {
            return listing.isComplete ? false : nil
        }
        switch documents.kind {
        case .symlink: return false
        case .file: return true
        case .other: return nil
        case .directory:
            switch FolderReader.read(documents.url) {
            case .failure(let failure): return failure.isMissing ? false : nil
            case .success(let inside):
                if !inside.entries.isEmpty { return true }
                return inside.isComplete ? false : nil
            }
        }
    }

    /// A measured entry, with what a `Finding` needs.
    private struct Measured {
        var fsid: UInt64
        var fileID: UInt64
        var flags: UInt32
        var allocatedBytes: Int64
        var privateBytes: Int64
        var newest: Date?
        var isDirectory: Bool
        var itemCount: Int
        var isPartial: Bool
        /// True when one of the largest files inside is a virtual machine or disk image. Only set when asked for.
        var holdsDiskImage = false

        func finding(for url: URL) -> Finding {
            Finding(
                ruleID: UninstallRule.id, url: url, fsid: fsid, fileID: fileID,
                allocatedBytes: allocatedBytes, privateBytes: privateBytes, newestModification: newest,
                isDirectory: isDirectory, isSymlink: false, flags: flags, itemCount: itemCount)
        }
    }

    private static func measure(_ entry: FolderEntry, lookForDiskImages: Bool = false) async -> Measured? {
        switch entry.kind {
        case .directory: return await measureDirectory(entry.url, lookForDiskImages: lookForDiskImages)
        case .file: return measureFile(entry)
        case .symlink, .other: return nil
        }
    }

    /// Largest files kept to look for a virtual machine or disk image among them.
    private static let diskImageLookupCount = 5

    private static func measureDirectory(_ url: URL, lookForDiskImages: Bool = false) async -> Measured? {
        let options = WalkOptions(
            maxWorkers: 3, totalsDepth: 0, topFilesCount: lookForDiskImages ? diskImageLookupCount : 0)
        guard let result = try? await SharedBudgetWalk.walk(url, options: options), let root = result.nodes.first else {
            return nil
        }
        let holdsDiskImage = result.topFiles.contains {
            LeftoverMatcher.isVirtualMachineOrDiskImage(
                name: $0.url.lastPathComponent, allocatedBytes: $0.allocatedBytes)
        }
        return Measured(
            fsid: root.id.fsid, fileID: root.id.fileID, flags: root.flags,
            allocatedBytes: root.allocatedBytes, privateBytes: root.privateBytes,
            newest: root.newestModification, isDirectory: true,
            itemCount: result.files + result.directories + result.symlinks,
            isPartial: result.partial || result.deniedCount > 0 || result.otherErrors > 0,
            holdsDiskImage: holdsDiskImage)
    }

    private static func measureFile(_ entry: FolderEntry) -> Measured? {
        guard let identity = EntryStat.identity(of: entry.path) else { return nil }
        var info = stat()
        guard lstat(entry.path, &info) == 0 else { return nil }
        let modified = Date(
            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) * 1e-9)
        return Measured(
            fsid: identity.fsid, fileID: identity.fileID, flags: entry.flags,
            allocatedBytes: entry.allocatedBytes, privateBytes: entry.allocatedBytes,
            newest: modified, isDirectory: false, itemCount: 1, isPartial: false)
    }
}

/// `(fsid, fileID)` of one entry, read the way the safety gate re-reads it.
enum EntryStat {
    /// Reads the entry itself with `getattrlist` and `FSOPT_NOFOLLOW`. `fsid` is packed like the walker does.
    static func identity(of path: [CChar]) -> (fsid: UInt64, fileID: UInt64)? {
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_FSID) | attrgroup_t(ATTR_CMN_FILEID)
        // Reply: u32 length, fsid (2 x i32), file ID (u64).
        var reply = [UInt8](repeating: 0, count: 64)
        let result = reply.withUnsafeMutableBytes { bytes in
            getattrlist(path, &list, bytes.baseAddress, bytes.count, UInt32(FSOPT_NOFOLLOW))
        }
        guard result == 0 else { return nil }
        return reply.withUnsafeBytes { bytes in
            guard bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self) >= 20 else { return nil }
            let first = bytes.loadUnaligned(fromByteOffset: 4, as: Int32.self)
            let second = bytes.loadUnaligned(fromByteOffset: 8, as: Int32.self)
            let fileID = bytes.loadUnaligned(fromByteOffset: 12, as: UInt64.self)
            return (packFSID(first, second), fileID)
        }
    }
}
