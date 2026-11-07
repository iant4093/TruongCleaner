import Foundation

/// One Xcode simulator device, from `xcrun simctl list devices --json`.
public struct SimulatorDevice: Sendable, Hashable {
    /// The device's UUID.
    public let udid: String
    /// Display name, for example `iPhone 18 Pro`.
    public let name: String
    /// Identifier of the runtime key it is listed under, for example `com.apple.CoreSimulator.SimRuntime.iOS-27-0`.
    public let runtimeID: String
    /// Raw `simctl` state, for example `Shutdown` or `Booted`.
    public let state: String
    /// `false` when the device's runtime is gone or `simctl` marks it unavailable.
    public let isAvailable: Bool
    /// The device's data folder, if `simctl` reports one.
    public let dataPath: URL?
    /// When the device was last booted or used, if `simctl` reports it.
    public let lastBootedAt: Date?

    /// Creates a device value.
    public init(
        udid: String, name: String, runtimeID: String, state: String,
        isAvailable: Bool, dataPath: URL?, lastBootedAt: Date?
    ) {
        self.udid = udid
        self.name = name
        self.runtimeID = runtimeID
        self.state = state
        self.isAvailable = isAvailable
        self.dataPath = dataPath
        self.lastBootedAt = lastBootedAt
    }
}

/// One installed simulator runtime, from `xcrun simctl runtime list --json`.
public struct SimulatorRuntime: Sendable, Hashable {
    /// The runtime's UUID, the value `simctl runtime delete` takes.
    public let identifier: String
    /// Display name, for example `iOS 27.0`.
    public let name: String
    /// Version string, for example `27.0`.
    public let version: String
    /// Size on disk in bytes, if `simctl` reports it.
    public let sizeBytes: Int64?
    /// When the runtime was last used, if `simctl` reports it.
    public let lastUsedAt: Date?
    /// Whether `simctl` says this runtime can be deleted. `nil` = unknown.
    public let isDeletable: Bool?

    /// Creates a runtime value.
    public init(
        identifier: String, name: String, version: String,
        sizeBytes: Int64?, lastUsedAt: Date?, isDeletable: Bool?
    ) {
        self.identifier = identifier
        self.name = name
        self.version = version
        self.sizeBytes = sizeBytes
        self.lastUsedAt = lastUsedAt
        self.isDeletable = isDeletable
    }
}

/// Lists simulators and runtimes with `xcrun simctl` (list verbs only).
public enum Simulators {
    /// Lists all simulator devices. Returns `.failure(.toolMissing)` when Xcode is not installed.
    public static func devices() async -> Result<[SimulatorDevice], ProbeError> {
        let result = await ReadOnlyCommand.run(
            "/usr/bin/xcrun", ["simctl", "list", "devices", "--json"], timeout: .seconds(30)
        )
        if let failure = result.probeError(tool: "xcrun") { return .failure(failure) }
        do {
            return .success(try SimctlParser.devices(json: result.stdout))
        } catch {
            return .failure(error)
        }
    }

    /// Lists installed simulator runtimes. Returns `.failure(.toolMissing)` when Xcode is not installed.
    public static func runtimes() async -> Result<[SimulatorRuntime], ProbeError> {
        let result = await ReadOnlyCommand.run(
            "/usr/bin/xcrun", ["simctl", "runtime", "list", "--json"], timeout: .seconds(30)
        )
        if let failure = result.probeError(tool: "xcrun") { return .failure(failure) }
        do {
            return .success(try SimctlParser.runtimes(json: result.stdout))
        } catch {
            return .failure(error)
        }
    }
}

/// Parses `simctl` JSON. Unknown fields are ignored.
enum SimctlParser {
    private struct DevicesDocument: Decodable {
        let devices: [String: [DeviceEntry]]
    }

    private struct DeviceEntry: Decodable {
        let udid: String
        let name: String
        let state: String?
        let isAvailable: Bool?
        let availability: String?
        let dataPath: String?
        let lastBootedAt: String?
        let lastUsedAt: String?
    }

    private struct RuntimeEntry: Decodable {
        let identifier: String?
        let runtimeIdentifier: String?
        let version: String?
        let sizeBytes: Int64?
        let lastUsedAt: String?
        let deletable: Bool?
    }

    /// - Throws: ``ProbeError/parse(_:)`` when the JSON is not a `devices` dictionary of device arrays.
    static func devices(json: Data) throws(ProbeError) -> [SimulatorDevice] {
        let document: DevicesDocument
        do {
            document = try JSONDecoder().decode(DevicesDocument.self, from: json)
        } catch {
            throw .parse("simctl devices JSON not understood")
        }
        var devices: [SimulatorDevice] = []
        for runtimeID in document.devices.keys.sorted() {
            for entry in document.devices[runtimeID] ?? [] {
                devices.append(SimulatorDevice(
                    udid: entry.udid,
                    name: entry.name,
                    runtimeID: runtimeID,
                    state: entry.state ?? "Unknown",
                    // Older Xcode prints "availability": "(available)" instead of a Bool.
                    isAvailable: entry.isAvailable ?? (entry.availability == "(available)"),
                    dataPath: entry.dataPath.map { URL(fileURLWithPath: $0) },
                    lastBootedAt: (entry.lastBootedAt ?? entry.lastUsedAt).flatMap(date(fromISO8601:))
                ))
            }
        }
        return devices
    }

    /// - Throws: ``ProbeError/parse(_:)`` when the JSON is not a dictionary of runtime objects.
    static func runtimes(json: Data) throws(ProbeError) -> [SimulatorRuntime] {
        let entries: [String: RuntimeEntry]
        do {
            entries = try JSONDecoder().decode([String: RuntimeEntry].self, from: json)
        } catch {
            throw .parse("simctl runtime JSON not understood")
        }
        return entries.keys.sorted().compactMap { key in
            guard let entry = entries[key] else { return nil }
            let version = entry.version ?? ""
            return SimulatorRuntime(
                identifier: entry.identifier ?? key,
                name: displayName(runtimeIdentifier: entry.runtimeIdentifier, version: version, fallback: key),
                version: version,
                sizeBytes: entry.sizeBytes,
                lastUsedAt: entry.lastUsedAt.flatMap(date(fromISO8601:)),
                isDeletable: entry.deletable
            )
        }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-27-0` + `27.0` becomes `iOS 27.0`.
    private static func displayName(runtimeIdentifier: String?, version: String, fallback: String) -> String {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard
            let runtimeIdentifier, runtimeIdentifier.hasPrefix(prefix),
            let platform = runtimeIdentifier.dropFirst(prefix.count).split(separator: "-").first
        else { return fallback }
        return version.isEmpty ? String(platform) : "\(platform) \(version)"
    }

    private static func date(fromISO8601 text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
