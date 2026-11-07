import Foundation

/// Builds the whole report and writes it under `spikes/s4-volume/out/`.
enum Report {
    static let volumePaths = ["/", "/System/Volumes/Data"]

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("s4volume: \(message)\n".utf8))
    }

    static func build(startedAt: Date) -> JSONValue {
        log("volumes")
        let volumes = volumePaths.map { VolumeProbe.report(path: $0) }
        log("snapshots")
        let snapshots = SystemProbe.snapshots()
        log("apfs")
        let apfs = SystemProbe.apfs()
        log("swap")
        let swap = SystemProbe.swap()
        log("protected paths")
        let paths = PathProbe.paths.map { PathProbe.probe(path: $0) }
        log("AssetsV2 walk (60 s cap)")
        let assets = AllocatedSizeWalk.measure(path: "/System/Library/AssetsV2", cap: 60)
        log("system_profiler")
        let profiler = SystemProbe.systemProfiler()

        return [
            "tool": "s4volume",
            "generatedAt": .string(ISO8601DateFormatter().string(from: startedAt)),
            "host": SystemProbe.host(),
            "volumes": .array(volumes),
            "snapshots": snapshots,
            "apfs": apfs,
            "swap": swap,
            "pathsReadableWithoutRoot": .array(paths),
            "assetsV2Size": assets,
            "systemProfiler": profiler,
        ]
    }

    /// `spikes/s4-volume`, found from this source file's path (Sources/s4volume/Report.swift).
    static func packageDirectory(filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func write(_ data: Data, startedAt: Date) throws -> URL {
        let directory = packageDirectory().appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let file = directory.appendingPathComponent("volume-\(formatter.string(from: startedAt)).json")
        try data.write(to: file, options: .atomic)
        return file
    }
}
