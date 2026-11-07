import Darwin
import Foundation

// s1walker --method <bulk|fm|fts> --workers <n> [--limit-seconds <s>] [--json] <root>

private let usage = "usage: s1walker --method <bulk|fm|fts> --workers <n> [--limit-seconds <s>] [--json] <root>\n"

private func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data(("s1walker: " + message + "\n").utf8))
    if code == 2 { FileHandle.standardError.write(Data(usage.utf8)) }
    exit(code)
}

private struct Options {
    var method = ""
    var workers = 1
    var limitSeconds: Double?
    var json = false
    var root = ""
}

private func parseOptions(_ args: [String]) -> Options {
    var options = Options()
    var index = 0
    func value(for flag: String) -> String {
        index += 1
        guard index < args.count else { fail("\(flag) needs a value", code: 2) }
        return args[index]
    }
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--method": options.method = value(for: arg)
        case "--workers":
            guard let n = Int(value(for: arg)), n >= 1, n <= 64 else { fail("--workers must be 1...64", code: 2) }
            options.workers = n
        case "--limit-seconds":
            guard let s = Double(value(for: arg)), s > 0 else { fail("--limit-seconds must be > 0", code: 2) }
            options.limitSeconds = s
        case "--json": options.json = true
        default:
            if arg.hasPrefix("--") { fail("unknown option \(arg)", code: 2) }
            if !options.root.isEmpty { fail("only one root allowed", code: 2) }
            options.root = arg
        }
        index += 1
    }
    guard ["bulk", "fm", "fts"].contains(options.method) else { fail("--method must be bulk, fm or fts", code: 2) }
    guard !options.root.isEmpty else { fail("missing <root>", code: 2) }
    return options
}

private let options = parseOptions(Array(CommandLine.arguments.dropFirst()))

// The root must be a real directory, not a symlink: nothing here follows links.
private var rootStatus = stat()
guard lstat(options.root, &rootStatus) == 0 else {
    fail("cannot stat \(options.root): \(String(cString: strerror(errno)))", code: 1)
}
guard (rootStatus.st_mode & S_IFMT) == S_IFDIR else {
    fail("\(options.root) is not a directory (symlink roots are refused)", code: 1)
}

raiseFileLimit()
private let stop = StopControl(limitSeconds: options.limitSeconds)
private let started = ContinuousClock.now
private let counters: Counters
switch options.method {
case "bulk": counters = runBulk(root: options.root, workers: options.workers, stop: stop)
case "fm": counters = runFileManager(root: options.root, workers: options.workers, stop: stop)
default: counters = runFts(root: options.root, workers: options.workers, stop: stop)
}
private let elapsed = ContinuousClock.now - started
private let wall = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

private let result = BenchResult(
    method: options.method, workers: options.workers, root: options.root,
    files: counters.files, dirs: counters.dirs, symlinks: counters.symlinks,
    hardlinkDupesSkipped: counters.hardlinkDupesSkipped,
    permissionDenied: counters.permissionDenied, otherErrors: counters.otherErrors,
    crossDeviceSkipped: counters.crossDeviceSkipped,
    allocatedBytes: counters.allocatedBytes, wallSeconds: wall,
    filesPerSecond: wall > 0 ? Double(counters.files) / wall : 0,
    peakRSSBytes: peakRSSBytes(), partial: stop.tripped)

if options.json {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(result), let line = String(data: data, encoding: .utf8) {
        print(line)
    } else {
        fail("could not encode result", code: 1)
    }
} else {
    print(result.textLine)
}
