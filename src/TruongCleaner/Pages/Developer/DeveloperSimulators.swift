import CleanerScanner
import Foundation

/// A size that is being measured, known, or could not be read. Unknown is not zero.
nonisolated enum MeasuredSize: Sendable, Equatable {
    case measuring
    case bytes(Int64)
    case unknown
}

/// One simulator device in the table.
nonisolated struct SimulatorDeviceRow: Identifiable, Sendable {
    let udid: String
    let name: String
    /// "iOS 27.0", read from the runtime key `simctl` lists the device under.
    let runtimeName: String
    /// Raw `simctl` state. `Shutdown` is the only state that may be deleted.
    let state: String
    let isAvailable: Bool
    let lastUsed: Date?
    var size: MeasuredSize

    var id: String { udid }

    var isShutDown: Bool { state == "Shutdown" }

    /// Plain-words state.
    var stateText: String {
        switch state {
        case "Shutdown": "Shut down"
        case "Booted": "Running"
        default: state
        }
    }
}

/// One simulator runtime (a simulator OS) in the table.
nonisolated struct SimulatorRuntimeRow: Identifiable, Sendable {
    let identifier: String
    let name: String
    let version: String
    /// Size as `simctl` reports it, or `nil` when it does not.
    let bytes: Int64?
    let lastUsed: Date?
    /// `false` only when `simctl` says the runtime cannot be deleted.
    let isDeletable: Bool

    var id: String { identifier }
}

/// What reading the simulator lists gave.
nonisolated struct SimulatorSnapshot: Sendable {
    var devices: [SimulatorDeviceRow]
    var runtimes: [SimulatorRuntimeRow]
    /// Set when the runtime list could not be read although the device list could.
    var runtimeNote: String?
}

/// Reads the simulator lists with `simctl list` and measures each device's data folder.
nonisolated enum SimulatorLoader {
    /// Folders measured at the same time. Each walk uses two workers, so at most eight threads.
    private static let concurrentMeasurements = 4

    /// Why the lists could not be read, in plain words.
    enum Failure: Error, Sendable {
        case xcodeMissing
        case unreadable

        var message: String {
            switch self {
            case .xcodeMissing: "Xcode is not installed, so there are no simulators."
            case .unreadable: "The simulator list could not be read."
            }
        }
    }

    /// Lists devices and runtimes without sizes. Device sizes are `measuring`.
    @concurrent
    static func list() async -> Result<SimulatorSnapshot, Failure> {
        async let devices = Simulators.devices()
        async let runtimes = Simulators.runtimes()
        let (deviceResult, runtimeResult) = await (devices, runtimes)

        let found: [SimulatorDevice]
        switch deviceResult {
        case .success(let list): found = list
        case .failure(.toolMissing): return .failure(.xcodeMissing)
        case .failure: return .failure(.unreadable)
        }

        var snapshot = SimulatorSnapshot(
            devices: found.map {
                SimulatorDeviceRow(
                    udid: $0.udid, name: $0.name, runtimeName: runtimeName(forKey: $0.runtimeID),
                    state: $0.state, isAvailable: $0.isAvailable, lastUsed: $0.lastBootedAt,
                    size: isSafeComponent($0.udid) ? .measuring : .unknown)
            }.sorted { ($0.runtimeName, $0.name) < ($1.runtimeName, $1.name) },
            runtimes: [],
            runtimeNote: nil)
        switch runtimeResult {
        case .success(let list):
            snapshot.runtimes = list.map {
                SimulatorRuntimeRow(
                    identifier: $0.identifier, name: $0.name, version: $0.version, bytes: $0.sizeBytes,
                    lastUsed: $0.lastUsedAt, isDeletable: $0.isDeletable ?? true)
            }
        case .failure:
            snapshot.runtimeNote = "The list of simulator runtimes could not be read."
        }
        return .success(snapshot)
    }

    /// Measures `~/Library/Developer/CoreSimulator/Devices/<UDID>` for each device with the bulk walker.
    ///
    /// Returns the size of every UDID given. A folder that is missing, refused or only partly read is
    /// `unknown`, never zero. Stops early when the calling task is cancelled.
    @concurrent
    static func measure(udids: [String], home: URL) async -> [String: MeasuredSize] {
        let devices = home.appending(path: "Library/Developer/CoreSimulator/Devices", directoryHint: .isDirectory)
        var sizes: [String: MeasuredSize] = [:]
        await withTaskGroup(of: (String, MeasuredSize).self) { group in
            var pending = udids.makeIterator()
            func startNext() {
                guard let udid = pending.next() else { return }
                group.addTask { (udid, await size(of: udid, in: devices)) }
            }
            for _ in 0..<concurrentMeasurements { startNext() }
            for await (udid, measured) in group {
                sizes[udid] = measured
                if Task.isCancelled {
                    group.cancelAll()
                } else {
                    startNext()
                }
            }
        }
        return sizes
    }

    private static func size(of udid: String, in devices: URL) async -> MeasuredSize {
        // A UDID that is not a plain folder name is never turned into a path.
        guard isSafeComponent(udid) else { return .unknown }
        let folder = devices.appending(path: udid, directoryHint: .isDirectory)
        let options = WalkOptions(maxWorkers: 2, totalsDepth: 0)
        guard let result = try? await BulkWalker.walk(folder, options: options),
              !result.partial, result.deniedCount == 0, result.otherErrors == 0,
              let root = result.nodes.first else { return .unknown }
        return .bytes(root.allocatedBytes)
    }

    /// Letters, digits and dashes only, 1 to 64 long.
    private static func isSafeComponent(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return (1...64).contains(bytes.count) && bytes.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || byte == UInt8(ascii: "-")
        }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-27-0` becomes `iOS 27.0`. Anything else is shown as it is.
    static func runtimeName(forKey key: String) -> String {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard key.hasPrefix(prefix) else { return key }
        let parts = key.dropFirst(prefix.count).split(separator: "-")
        guard let platform = parts.first, parts.count > 1 else { return key }
        return "\(platform) \(parts.dropFirst().joined(separator: "."))"
    }
}
