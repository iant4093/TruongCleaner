import Darwin
import Foundation

/// Numbers from `URLResourceValues`.
struct ResourceNumbers: Sendable {
    var total: Int64?
    var available: Int64?
    var important: Int64?
    var opportunistic: Int64?
}

/// Numbers from `statfs`, already multiplied by `f_bsize`.
struct StatfsNumbers: Sendable {
    var total: Int64?
    var free: Int64?
    var available: Int64?
    var used: Int64?
}

/// Numbers from `getattrlist` volume attributes.
struct AttrNumbers: Sendable {
    var size: Int64?
    var free: Int64?
    var available: Int64?
    var used: Int64?
}

/// Items 1 to 4 of the brief: volume capacity from three APIs, plus derived values.
enum VolumeProbe {
    // MARK: 1. URLResourceValues

    private static let resourceKeys: [(name: String, key: URLResourceKey)] = [
        ("volumeName", .volumeNameKey),
        ("volumeUUIDString", .volumeUUIDStringKey),
        ("volumeTotalCapacity", .volumeTotalCapacityKey),
        ("volumeAvailableCapacity", .volumeAvailableCapacityKey),
        ("volumeAvailableCapacityForImportantUsage", .volumeAvailableCapacityForImportantUsageKey),
        ("volumeAvailableCapacityForOpportunisticUsage", .volumeAvailableCapacityForOpportunisticUsageKey),
        ("volumeIsInternal", .volumeIsInternalKey),
        ("volumeSupportsFileCloning", .volumeSupportsFileCloningKey),
    ]

    /// Reads each key on its own so a failure names the key that failed.
    static func resourceValues(path: String) -> (json: JSONValue, numbers: ResourceNumbers) {
        let url = URL(fileURLWithPath: path)
        var entries: [String: JSONValue] = [:]
        var numbers = ResourceNumbers()
        for (name, key) in resourceKeys {
            let api = JSONValue.string("URL.resourceValues(forKeys: [.\(name)Key])")
            do {
                let values = try url.resourceValues(forKeys: [key])
                if let value = values.allValues[key] {
                    entries[name] = ["api": api, "value": JSONValue(any: value)]
                    let number = (value as? NSNumber)?.int64Value
                    switch name {
                    case "volumeTotalCapacity": numbers.total = number
                    case "volumeAvailableCapacity": numbers.available = number
                    case "volumeAvailableCapacityForImportantUsage": numbers.important = number
                    case "volumeAvailableCapacityForOpportunisticUsage": numbers.opportunistic = number
                    default: break
                    }
                } else {
                    entries[name] = ["api": api, "value": nil, "note": "call succeeded but the key was not provided"]
                }
            } catch {
                entries[name] = ["api": api, "error": .error(error)]
            }
        }
        return (.object(entries), numbers)
    }

    // MARK: 2. statfs

    static func statfsInfo(path: String) -> (json: JSONValue, numbers: StatfsNumbers) {
        var info = statfs()
        guard statfs(path, &info) == 0 else {
            let code = errno
            return (["api": "statfs(2)", "error": .errno(code)], StatfsNumbers())
        }
        let blockSize = UInt64(info.f_bsize)
        let blocks = UInt64(info.f_blocks)
        let freeBlocks = UInt64(info.f_bfree)
        let availableBlocks = UInt64(info.f_bavail)

        func bytes(_ blockCount: UInt64) -> Int64 { Int64(clamping: blockCount &* blockSize) }
        let numbers = StatfsNumbers(
            total: bytes(blocks),
            free: bytes(freeBlocks),
            available: bytes(availableBlocks),
            used: bytes(blocks &- freeBlocks)
        )
        let json: JSONValue = [
            "api": "statfs(2)",
            "f_bsize": .bytes(info.f_bsize),
            "f_iosize": .bytes(info.f_iosize),
            "f_blocks": .bytes(info.f_blocks),
            "f_bfree": .bytes(info.f_bfree),
            "f_bavail": .bytes(info.f_bavail),
            "f_fstypename": .string(cString(of: info.f_fstypename)),
            "f_mntfromname": .string(cString(of: info.f_mntfromname)),
            "f_mntonname": .string(cString(of: info.f_mntonname)),
            "bytes": [
                "total (f_blocks * f_bsize)": .optionalInt(numbers.total),
                "free (f_bfree * f_bsize)": .optionalInt(numbers.free),
                "available (f_bavail * f_bsize)": .optionalInt(numbers.available),
                "used ((f_blocks - f_bfree) * f_bsize)": .optionalInt(numbers.used),
            ],
        ]
        return (json, numbers)
    }

    /// NUL-terminated C char tuple (fixed-size array in C) to String.
    private static func cString<T>(of tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: 3. getattrlist

    private static let volumeAttributes: [(name: String, bit: UInt32)] = [
        ("ATTR_VOL_SIZE", UInt32(ATTR_VOL_SIZE)),
        ("ATTR_VOL_SPACEFREE", UInt32(ATTR_VOL_SPACEFREE)),
        ("ATTR_VOL_SPACEAVAIL", UInt32(ATTR_VOL_SPACEAVAIL)),
        ("ATTR_VOL_SPACEUSED", UInt32(ATTR_VOL_SPACEUSED)),
    ]

    /// Asks for `ATTR_VOL_INFO` alone, then each attribute on its own, so each errno is separate.
    static func attributeList(path: String) -> (json: JSONValue, numbers: AttrNumbers) {
        var entries: [String: JSONValue] = [:]
        var numbers = AttrNumbers()

        entries["ATTR_VOL_INFO"] = request(path: path, bit: 0).json
        for (name, bit) in volumeAttributes {
            let result = request(path: path, bit: bit)
            entries[name] = result.json
            switch name {
            case "ATTR_VOL_SIZE": numbers.size = result.value
            case "ATTR_VOL_SPACEFREE": numbers.free = result.value
            case "ATTR_VOL_SPACEAVAIL": numbers.available = result.value
            case "ATTR_VOL_SPACEUSED": numbers.used = result.value
            default: break
            }
        }
        return (.object(entries), numbers)
    }

    /// One `getattrlist` call: volattr = ATTR_VOL_INFO | bit. Buffer layout: u32 length, then one off_t.
    private static func request(path: String, bit: UInt32) -> (json: JSONValue, value: Int64?) {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.volattr = attrgroup_t(UInt32(ATTR_VOL_INFO) | bit)
        var buffer = [UInt8](repeating: 0, count: 64)
        let size = buffer.count
        let result = getattrlist(path, &list, &buffer, size, 0)
        guard result == 0 else {
            let code = errno
            return (["api": "getattrlist(2)", "error": .errno(code)], nil)
        }
        let length = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        var value: Int64?
        if bit != 0, length >= 12 {
            value = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
        }
        var json: [String: JSONValue] = [
            "api": "getattrlist(2)",
            "returnedLength": .int(Int64(length)),
        ]
        if bit != 0 {
            json["value"] = value.map { .int($0) } ?? .null
            if value == nil { json["note"] = "buffer too short for an off_t" }
        } else {
            json["note"] = "supported (no value; ATTR_VOL_INFO only flags a volume request)"
        }
        return (.object(json), value)
    }

    // MARK: 4. Derived

    static func derived(
        resource: ResourceNumbers, statfs: StatfsNumbers, attributes: AttrNumbers
    ) -> JSONValue {
        var out: [String: JSONValue] = [:]

        func put(_ name: String, _ formula: String, _ value: Int64?) {
            var entry: [String: JSONValue] = ["formula": .string(formula)]
            if let value {
                entry["bytes"] = .int(value)
                entry["human"] = .string(humanBytes(value))
            } else {
                entry["bytes"] = .null
                entry["note"] = "an input was missing"
            }
            out[name] = .object(entry)
        }
        func difference(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
            guard let lhs, let rhs else { return nil }
            return lhs - rhs
        }

        put("purgeable", "volumeAvailableCapacityForImportantUsage - volumeAvailableCapacity",
            difference(resource.important, resource.available))
        put("purgeableOpportunistic",
            "volumeAvailableCapacityForOpportunisticUsage - volumeAvailableCapacity",
            difference(resource.opportunistic, resource.available))
        put("usedFromURLValues", "volumeTotalCapacity - volumeAvailableCapacity",
            difference(resource.total, resource.available))
        put("usedIfPurgeableCountsAsFree", "volumeTotalCapacity - volumeAvailableCapacityForImportantUsage",
            difference(resource.total, resource.important))
        put("usedFromStatfsFree", "(f_blocks - f_bfree) * f_bsize", statfs.used)
        put("usedFromStatfsAvail", "(f_blocks - f_bavail) * f_bsize",
            difference(statfs.total, statfs.available))
        put("usedFromGetattrlist", "ATTR_VOL_SPACEUSED", attributes.used)
        put("usedFromGetattrlistSizeMinusFree", "ATTR_VOL_SIZE - ATTR_VOL_SPACEFREE",
            difference(attributes.size, attributes.free))
        put("usedFromGetattrlistSizeMinusAvail", "ATTR_VOL_SIZE - ATTR_VOL_SPACEAVAIL",
            difference(attributes.size, attributes.available))
        return .object(out)
    }

    static func report(path: String) -> JSONValue {
        let resource = resourceValues(path: path)
        let statfs = statfsInfo(path: path)
        let attributes = attributeList(path: path)
        return [
            "path": .string(path),
            "urlResourceValues": resource.json,
            "statfs": statfs.json,
            "getattrlist": attributes.json,
            "derived": derived(resource: resource.numbers, statfs: statfs.numbers, attributes: attributes.numbers),
        ]
    }
}
