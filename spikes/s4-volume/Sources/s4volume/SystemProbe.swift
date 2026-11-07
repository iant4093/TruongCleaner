import Darwin
import Foundation

/// Items 5 to 7 and 9 of the brief: command-based probes, all read-only.
enum SystemProbe {
    // MARK: 5. Snapshots

    static func snapshots() -> JSONValue {
        let names = CommandRunner.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 10)
        let dates = CommandRunner.run("/usr/bin/tmutil", ["listlocalsnapshotdates", "/"], timeout: 10)

        let nameLines = lines(names.stdoutString)
        let dateLines = lines(dates.stdoutString)
        let snapshotNames = nameLines.filter { $0.hasPrefix("com.apple.") }
        let parsed: [JSONValue] = snapshotNames.map { name in
            [
                "name": .string(name),
                "dateParsedFromName": date(in: name).map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            ]
        }
        let parsedDates: [JSONValue] = dateLines.compactMap { line in
            guard let date = date(in: line), line.first?.isNumber == true else { return nil }
            return [
                "text": .string(line),
                "iso8601": .string(ISO8601DateFormatter().string(from: date)),
            ]
        }
        return [
            "listlocalsnapshots": names.json(includeStdout: true),
            "listlocalsnapshotdates": dates.json(includeStdout: true),
            "snapshotCountFromNames": .bytes(snapshotNames.count),
            "snapshotCountFromDates": .bytes(parsedDates.count),
            "snapshots": .array(parsed),
            "dates": .array(parsedDates),
            "note": "tmutil prints no sizes. Names carry local time (yyyy-MM-dd-HHmmss).",
        ]
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Finds `yyyy-MM-dd-HHmmss` in a line and parses it in the local time zone.
    private static func date(in line: String) -> Date? {
        guard let match = line.firstMatch(of: /\d{4}-\d{2}-\d{2}-\d{6}/) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: String(match.output))
    }

    // MARK: 6. APFS container

    static func apfs() -> JSONValue {
        let info = CommandRunner.run("/usr/sbin/diskutil", ["info", "-plist", "/"], timeout: 10)
        let list = CommandRunner.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"], timeout: 20)

        var infoJSON: JSONValue = .null
        var rootContainer: String?
        if let dictionary = plistDictionary(info.stdout) {
            infoJSON = JSONValue(any: dictionary)
            rootContainer = dictionary["APFSContainerReference"] as? String
        }

        var containers: [JSONValue] = []
        var parseError: JSONValue = .null
        if let dictionary = plistDictionary(list.stdout) {
            let raw = dictionary["Containers"] as? [[String: Any]] ?? []
            containers = raw.map { container(from: $0, rootContainer: rootContainer) }
        } else if list.succeeded {
            parseError = "the plist could not be parsed"
        }
        return [
            "diskutilInfoRoot": ["command": info.json(includeStdout: false), "plist": infoJSON],
            "diskutilApfsList": [
                "command": list.json(includeStdout: false),
                "containers": .array(containers),
                "parseError": parseError,
            ],
            "rootContainerReference": rootContainer.map { .string($0) } ?? .null,
        ]
    }

    private static func plistDictionary(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    private static func pick(_ keys: [String], from dictionary: [String: Any]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for key in keys {
            if let value = dictionary[key] { out[key] = JSONValue(any: value) }
        }
        return out
    }

    private static func container(from raw: [String: Any], rootContainer: String?) -> JSONValue {
        let reference = raw["ContainerReference"] as? String
        var out = pick(
            ["ContainerReference", "CapacityCeiling", "CapacityFree", "CapacityInUse", "FusionContainer"],
            from: raw
        )
        out["availableKeys"] = .array(raw.keys.sorted().map { .string($0) })
        out["containsRoot"] = .bool(reference != nil && reference == rootContainer)
        if let stores = raw["PhysicalStores"] as? [[String: Any]] {
            out["physicalStores"] = .array(stores.map { .object(pick(["DeviceIdentifier", "Size"], from: $0)) })
        }

        let volumes = raw["Volumes"] as? [[String: Any]] ?? []
        out["volumes"] = .array(volumes.map {
            .object(pick(
                ["Name", "DeviceIdentifier", "Roles", "CapacityInUse", "CapacityQuota", "CapacityReserve",
                 "Sealed", "FileVault"],
                from: $0
            ))
        })

        let ceiling = (raw["CapacityCeiling"] as? NSNumber)?.int64Value
        let free = (raw["CapacityFree"] as? NSNumber)?.int64Value
        let sum = volumes.compactMap { ($0["CapacityInUse"] as? NSNumber)?.int64Value }.reduce(0, +)
        if let ceiling, let free {
            out["derived"] = [
                "usedFromCeilingMinusFree": ["bytes": .int(ceiling - free), "human": .string(humanBytes(ceiling - free))],
                "sumOfVolumeCapacityInUse": ["bytes": .int(sum), "human": .string(humanBytes(sum))],
                "differenceCeilingMinusFreeMinusSum": [
                    "bytes": .int(ceiling - free - sum),
                    "human": .string(humanBytes(ceiling - free - sum)),
                ],
            ]
        }
        return .object(out)
    }

    // MARK: 7. Swap

    static func swap() -> JSONValue {
        let command = CommandRunner.run("/usr/sbin/sysctl", ["-n", "vm.swapusage"], timeout: 10)

        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let status = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        var api: JSONValue
        if status == 0 {
            api = [
                "api": "sysctlbyname(\"vm.swapusage\") -> xsw_usage",
                "total": ["bytes": .bytes(usage.xsu_total), "human": .string(humanBytes(Int64(clamping: usage.xsu_total)))],
                "used": ["bytes": .bytes(usage.xsu_used), "human": .string(humanBytes(Int64(clamping: usage.xsu_used)))],
                "available": ["bytes": .bytes(usage.xsu_avail), "human": .string(humanBytes(Int64(clamping: usage.xsu_avail)))],
                "encrypted": .bool(usage.xsu_encrypted != 0),
            ]
        } else {
            let code = errno
            api = ["api": "sysctlbyname(\"vm.swapusage\")", "error": .errno(code)]
        }
        return [
            "command": command.json(includeStdout: true),
            "sysctlbyname": api,
        ]
    }

    // MARK: 9. system_profiler

    static func systemProfiler() -> JSONValue {
        let command = CommandRunner.run("/usr/sbin/system_profiler", ["SPStorageDataType", "-json"], timeout: 60)
        var volumes: [JSONValue] = []
        var parseError: JSONValue = .null
        if !command.stdout.isEmpty {
            if let root = (try? JSONSerialization.jsonObject(with: command.stdout)) as? [String: Any],
               let items = root["SPStorageDataType"] as? [[String: Any]] {
                volumes = items.map {
                    .object(pick(["_name", "mount_point", "bsd_name", "size_in_bytes", "free_space_in_bytes"], from: $0))
                }
            } else if command.succeeded {
                parseError = "SPStorageDataType not found in the JSON"
            }
        }
        return [
            "command": command.json(includeStdout: false),
            "volumes": .array(volumes),
            "parseError": parseError,
        ]
    }

    // MARK: Host

    static func host() -> JSONValue {
        [
            "osVersionString": .string(ProcessInfo.processInfo.operatingSystemVersionString),
            "kern.osversion": sysctlString("kern.osversion").map { .string($0) } ?? .null,
            "hw.machine": sysctlString("hw.machine").map { .string($0) } ?? .null,
            "hw.model": sysctlString("hw.model").map { .string($0) } ?? .null,
            "euid": .int(Int64(geteuid())),
            "environment": "run as the logged-in user, no sudo",
        ]
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
