// Dev-only benchmark tool. Not part of the app.
// Further scenarios arrive in task 2.6.
import CleanerCore
import CleanerScanner
import Darwin
import Foundation

let usage = """
usage: tcbench <scenario> [options]

Dev-only benchmark tool for CleanerKit.

scenarios:
  volume
      Print volume capacity, snapshots, swap and simulator counts (read-only).
  walk <root> [--workers n] [--depth d]
      Walk <root> with BulkWalker and print a summary (no per-file output).
      --workers n   worker threads, 1...8 (default: min(8, cores))
      --depth d     keep folder totals to depth d below the root (default: 1)
      --prune a,b   total folders with these names as one node (for example node_modules)
      --keep a,b    with --prune: direct children with these names keep their own node (for example .git)
"""

/// Peak resident set size in bytes (`ru_maxrss` is bytes on macOS).
func peakResidentBytes() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int(usage.ru_maxrss)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func runWalk(_ arguments: [String]) async {
    var root: String?
    var workers = min(8, ProcessInfo.processInfo.activeProcessorCount)
    var depth = 1
    var prune: Set<String> = []
    var keep: Set<String> = []
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--workers", "--depth":
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value >= 0 else {
                fail("\(argument) needs a number\n\n\(usage)")
            }
            if argument == "--workers" { workers = value } else { depth = value }
            index += 2
        case "--prune", "--keep":
            guard index + 1 < arguments.count else { fail("\(argument) needs a comma-separated list\n\n\(usage)") }
            let names = Set(arguments[index + 1].split(separator: ",").map(String.init))
            if argument == "--prune" { prune = names } else { keep = names }
            index += 2
        default:
            guard root == nil, !argument.hasPrefix("--") else { fail("unexpected argument: \(argument)\n\n\(usage)") }
            root = argument
            index += 1
        }
    }
    guard let root else { fail("walk needs a root folder\n\n\(usage)") }
    guard workers >= 1 else { fail("--workers must be at least 1") }

    let url = URL(filePath: root, directoryHint: .isDirectory)
    let options = WalkOptions(maxWorkers: workers, totalsDepth: depth, pruneNames: prune, pruneKeepNames: keep)
    let clock = ContinuousClock()
    let start = clock.now
    let result: WalkResult
    do {
        result = try await BulkWalker.walk(url, options: options)
    } catch let error as ScanError {
        fail("walk failed: \(error.debugDetail)")
    } catch {
        fail("walk failed: \(error)")
    }
    let elapsed = clock.now - start
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    let rootNode = result.nodes.first

    func line(_ name: String, _ value: String) {
        print("\(name.padding(toLength: 22, withPad: " ", startingAt: 0))\(value)")
    }
    line("root", result.root.path)
    line("workers", "\(min(workers, min(8, ProcessInfo.processInfo.activeProcessorCount))) (requested \(workers))")
    line("totals depth", "\(depth) (\(result.nodes.count) nodes kept)")
    if !prune.isEmpty { line("pruned names", prune.sorted().joined(separator: ",")) }
    line("wall seconds", String(format: "%.3f", seconds))
    line("files", "\(result.files)")
    line("folders", "\(result.directories)")
    line("symlinks", "\(result.symlinks)")
    line("hard link duplicates", "\(result.hardLinkDuplicates)")
    line("cross-volume skipped", "\(result.crossVolumeSkipped)")
    line("denied folders", "\(result.deniedCount)")
    line("other errors", "\(result.otherErrors)")
    line("private size missing", "\(result.privateSizeMissing)")
    line("allocated", "\(rootNode?.allocatedBytes ?? 0) bytes (\(ByteFormatter.string(rootNode?.allocatedBytes ?? 0)))")
    line("private", "\(rootNode?.privateBytes ?? 0) bytes (\(ByteFormatter.string(rootNode?.privateBytes ?? 0)))")
    line("files per second", String(format: "%.0f", seconds > 0 ? Double(result.files) / seconds : 0))
    line("peak memory", ByteFormatter.string(Int64(peakResidentBytes())))
    line("partial", "\(result.partial)")
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "volume":
    await VolumeCommand.run()
case "walk":
    await runWalk(Array(arguments.dropFirst()))
case "scan-demo":
    await ScanDemoCommand.run(Array(arguments.dropFirst()))
case nil, "-h", "--help", "help":
    print(usage)
default:
    fail("unknown scenario: \(arguments[0])\n\n\(usage)")
}
