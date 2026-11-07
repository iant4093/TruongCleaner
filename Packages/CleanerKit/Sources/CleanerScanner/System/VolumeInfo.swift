import Darwin
import Foundation

/// Space numbers for the startup volume (`REQ-SYS-01`).
///
/// The first four values describe the whole APFS container, because that is what
/// `URLResourceValues` and `statfs` report. ``dataVolumeUsed`` and ``volumes`` give
/// per-volume use. A number that could not be read is `0` (capacities) or `nil` / empty
/// (the optional parts). Callers that need to tell "unknown" from zero should check
/// ``total`` first: it is `0` only when every probe failed.
public struct VolumeInfo: Sendable, Hashable {
    /// Container capacity in bytes.
    public let total: Int64
    /// Free bytes right now, not counting purgeable space.
    public let available: Int64
    /// Free bytes if macOS purges what it may purge (caches, local snapshots) for important files.
    public let availableForImportantUsage: Int64
    /// Free bytes if macOS purges what it may purge for opportunistic downloads.
    public let availableForOpportunisticUsage: Int64
    /// Used bytes of the whole container: ``total`` minus ``available``.
    public let containerUsed: Int64
    /// Bytes used by the Data volume (`ATTR_VOL_SPACEUSED` on `/System/Volumes/Data`), if readable.
    public let dataVolumeUsed: Int64?
    /// Per-volume use from `diskutil apfs list -plist` for the startup container. Empty if unavailable.
    public let volumes: [APFSVolumeUsage]

    /// Space macOS can free on its own: important-usage available minus available. Never negative.
    public var purgeable: Int64 { max(0, availableForImportantUsage - available) }

    /// Creates a value from known numbers. ``containerUsed`` is derived.
    public init(
        total: Int64,
        available: Int64,
        availableForImportantUsage: Int64,
        availableForOpportunisticUsage: Int64,
        dataVolumeUsed: Int64?,
        volumes: [APFSVolumeUsage]
    ) {
        self.total = total
        self.available = available
        self.availableForImportantUsage = availableForImportantUsage
        self.availableForOpportunisticUsage = availableForOpportunisticUsage
        self.containerUsed = max(0, total - available)
        self.dataVolumeUsed = dataVolumeUsed
        self.volumes = volumes
    }

    /// Reads the current numbers. Never throws; parts that fail are left at `0`, `nil` or empty.
    @concurrent
    public static func current() async -> VolumeInfo {
        async let volumes = apfsVolumes()
        let capacity = Capacity.read(path: "/")
        let dataUsed = spaceUsed(path: "/System/Volumes/Data")
        return VolumeInfo(
            total: capacity.total,
            available: capacity.available,
            availableForImportantUsage: capacity.important,
            availableForOpportunisticUsage: capacity.opportunistic,
            dataVolumeUsed: dataUsed,
            volumes: await volumes
        )
    }

    // MARK: Capacity

    /// Capacity values with fallbacks: `URLResourceValues` first, `statfs` if a key is missing.
    struct Capacity {
        var total: Int64
        var available: Int64
        var important: Int64
        var opportunistic: Int64

        static func read(path: String) -> Capacity {
            let url = URL(fileURLWithPath: path)
            let keys: Set<URLResourceKey> = [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityForOpportunisticUsageKey,
            ]
            let values = try? url.resourceValues(forKeys: keys)
            let fallback = statfsNumbers(path: path)

            let total = values?.volumeTotalCapacity.map(Int64.init) ?? fallback?.total ?? 0
            let available = values?.volumeAvailableCapacity.map(Int64.init) ?? fallback?.available ?? 0
            // Missing purgeable-aware values mean "nothing purgeable", never a negative number.
            let important = values?.volumeAvailableCapacityForImportantUsage ?? available
            let opportunistic = values?.volumeAvailableCapacityForOpportunisticUsage ?? available
            return Capacity(total: total, available: available, important: important, opportunistic: opportunistic)
        }

        private static func statfsNumbers(path: String) -> (total: Int64, available: Int64)? {
            var info = statfs()
            guard statfs(path, &info) == 0 else { return nil }
            let blockSize = UInt64(info.f_bsize)
            return (
                Int64(clamping: UInt64(info.f_blocks) &* blockSize),
                Int64(clamping: UInt64(info.f_bavail) &* blockSize)
            )
        }
    }

    // MARK: ATTR_VOL_SPACEUSED

    /// Bytes used on the volume at `path`, via `getattrlist(ATTR_VOL_SPACEUSED)`. `nil` on any error.
    static func spaceUsed(path: String) -> Int64? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.volattr = attrgroup_t(UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_SPACEUSED))
        // Result layout: u32 total length, then one off_t.
        var buffer = [UInt8](repeating: 0, count: 64)
        let size = buffer.count
        guard getattrlist(path, &list, &buffer, size, 0) == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            let length = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            guard length >= 12 else { return nil }
            let value = raw.loadUnaligned(fromByteOffset: 4, as: Int64.self)
            return value >= 0 ? value : nil
        }
    }

    // MARK: diskutil

    /// Volumes of the startup container. Empty when `diskutil` fails or the output is not understood.
    private static func apfsVolumes() async -> [APFSVolumeUsage] {
        async let list = ReadOnlyCommand.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"], timeout: .seconds(20))
        async let info = ReadOnlyCommand.run("/usr/sbin/diskutil", ["info", "-plist", "/"], timeout: .seconds(10))
        let (listResult, infoResult) = await (list, info)
        guard listResult.succeeded, let containers = try? APFSListParser.parse(plist: listResult.stdout) else {
            return []
        }
        // If `info` fails, the parser falls back to the single container with a Data volume.
        let reference = infoResult.succeeded
            ? try? APFSListParser.containerReference(infoPlist: infoResult.stdout)
            : nil
        return APFSListParser.startupContainer(in: containers, reference: reference)?.volumes ?? []
    }
}
