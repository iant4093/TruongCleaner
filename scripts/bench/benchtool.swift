// Measurement helper for scripts/bench.sh. Dev-only, never shipped, never imported by the app.
// Build: swiftc -O -parse-as-library -swift-version 6 -o build/bench/bin/benchtool scripts/bench/benchtool.swift
//
// Every subcommand prints one JSON object on one line to stdout and exits 0, or prints
// {"error": "..."} and exits 1. Nothing here writes to disk, cleans or deletes anything. The only
// process it ends is the one that `quit` is told to end, and only when that process runs the
// executable of the app that was passed in.
//
//   launch <app> [--timeout s] [-- app arguments...]   open -n the app; time until its first window
//   usage  <pid> <seconds>                               CPU, wakeups and memory over a period
//   watch  <pid> [--max s] [--min s] [--start-timeout s] follow a scan until the process goes quiet
//   settle <pid> [--max s]                               wait until the process has been quiet for 5 s
//   quit   <pid> <app>                                   SIGTERM (then SIGKILL) a process of <app>
//   analyze <sample-file>                                main-thread busy share and timer frames
import CoreGraphics
import Darwin
import Foundation

// MARK: Output

func emit(_ object: [String: Any]) -> Never {
    emitLine(object)
    exit(0)
}

func emitLine(_ object: [String: Any]) {
    let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: options),
          let text = String(data: data, encoding: .utf8) else {
        print("{\"error\":\"could not encode result\"}")
        return
    }
    print(text)
}

func fail(_ message: String, extra: [String: Any] = [:]) -> Never {
    var object = extra
    object["error"] = message
    emitLine(object)
    exit(1)
}

// MARK: Clock and processes

func nowNanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

func milliseconds(from start: UInt64, to end: UInt64) -> Double {
    Double(end - start) / 1_000_000
}

func executablePath(of pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
}

func allPIDs() -> [pid_t] {
    let needed = proc_listallpids(nil, 0)
    guard needed > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(needed) + 64)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard count > 0 else { return [] }
    return Array(pids.prefix(Int(count))).filter { $0 > 0 }
}

/// The real path of the executable inside an app bundle, or nil if the bundle cannot be read.
func appExecutable(_ appPath: String) -> String? {
    let url = URL(filePath: appPath, directoryHint: .isDirectory)
    return Bundle(url: url)?.executableURL?.resolvingSymlinksInPath().path
}

struct Usage {
    var cpuNanoseconds: UInt64
    var footprint: UInt64
    var peakFootprint: UInt64
    var interruptWakeups: UInt64
    var idleWakeups: UInt64
}

enum Timebase {
    static let info: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks * UInt64(info.numer) / UInt64(max(info.denom, 1))
    }
}

func readUsage(_ pid: pid_t) -> Usage? {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    guard status == 0 else { return nil }
    return Usage(
        cpuNanoseconds: Timebase.nanoseconds(info.ri_user_time) + Timebase.nanoseconds(info.ri_system_time),
        footprint: info.ri_phys_footprint,
        peakFootprint: info.ri_lifetime_max_phys_footprint,
        interruptWakeups: info.ri_interrupt_wkups,
        idleWakeups: info.ri_pkg_idle_wkups
    )
}

func sleepMilliseconds(_ value: UInt32) {
    usleep(value * 1000)
}

// MARK: Arguments

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var passthrough: [String] = []

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            let item = raw[index]
            if item == "--" {
                passthrough = Array(raw[(index + 1)...])
                return
            }
            if item.hasPrefix("--"), index + 1 < raw.count {
                options[String(item.dropFirst(2))] = raw[index + 1]
                index += 2
            } else {
                positional.append(item)
                index += 1
            }
        }
    }

    func number(_ name: String, default value: Double) -> Double {
        options[name].flatMap(Double.init) ?? value
    }
}

// MARK: Subcommands

func launch(_ arguments: Arguments) -> Never {
    guard let app = arguments.positional.first else { fail("launch needs an app path") }
    guard let executable = appExecutable(app) else { fail("cannot read the executable of \(app)") }
    let timeout = arguments.number("timeout", default: 20)

    let running = allPIDs().filter { executablePath(of: $0) == executable }
    if let first = running.first {
        fail("an instance of this app is already running (pid \(first))", extra: ["pid": Int(first)])
    }

    let opener = Process()
    opener.executableURL = URL(filePath: "/usr/bin/open")
    opener.arguments = ["-n", app] + (arguments.passthrough.isEmpty ? [] : ["--args"] + arguments.passthrough)
    let started = nowNanoseconds()
    do { try opener.run() } catch { fail("could not run open: \(error)") }

    var checked: [pid_t: Bool] = [:]
    while milliseconds(from: started, to: nowNanoseconds()) < timeout * 1000 {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? Int32,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
                  width >= 300, height >= 200 else { continue }
            let isOurs = checked[owner] ?? (executablePath(of: owner) == executable)
            checked[owner] = isOurs
            if isOurs {
                let shown = nowNanoseconds()
                emit(["pid": Int(owner), "windowMs": milliseconds(from: started, to: shown)])
            }
        }
        sleepMilliseconds(10)
    }
    let leftover = allPIDs().first { executablePath(of: $0) == executable }
    fail("no window within \(Int(timeout)) s (is a user session logged in?)", extra: leftover.map { ["pid": Int($0)] } ?? [:])
}

func usage(_ arguments: Arguments) -> Never {
    guard arguments.positional.count == 2, let rawPID = Int32(arguments.positional[0]),
          let seconds = Int(arguments.positional[1]), seconds > 0 else { fail("usage needs <pid> <seconds>") }
    guard let first = readUsage(rawPID) else { fail("cannot read process \(rawPID)") }
    let started = nowNanoseconds()
    var previous = first
    var previousTime = started
    var worst = 0.0
    var last = first
    for _ in 0..<seconds {
        sleep(1)
        guard let current = readUsage(rawPID) else { fail("process \(rawPID) went away") }
        let now = nowNanoseconds()
        let wall = Double(now - previousTime)
        let cpu = Double(current.cpuNanoseconds &- previous.cpuNanoseconds)
        worst = max(worst, cpu / wall * 100)
        previous = current
        previousTime = now
        last = current
    }
    let wallTotal = Double(previousTime - started)
    let cpuTotal = Double(last.cpuNanoseconds &- first.cpuNanoseconds)
    emit([
        "seconds": wallTotal / 1e9,
        "cpuSeconds": cpuTotal / 1e9,
        "cpuMeanPercent": cpuTotal / wallTotal * 100,
        "cpuMaxPercent": worst,
        "wakeupsPerSecond": Double(last.interruptWakeups &- first.interruptWakeups) / (wallTotal / 1e9),
        "idleWakeupsPerSecond": Double(last.idleWakeups &- first.idleWakeups) / (wallTotal / 1e9),
        "footprintBytes": Int(last.footprint),
        "peakFootprintBytes": Int(last.peakFootprint),
    ])
}

func watch(_ arguments: Arguments) -> Never {
    guard let rawString = arguments.positional.first, let pid = Int32(rawString) else { fail("watch needs a pid") }
    let maxSeconds = arguments.number("max", default: 120)
    let minSeconds = arguments.number("min", default: 4)
    let startTimeout = arguments.number("start-timeout", default: 20)
    guard var previous = readUsage(pid) else { fail("cannot read process \(pid)") }
    let begun = nowNanoseconds()
    var previousTime = begun
    var firstBusy: UInt64?
    var lastBusy: UInt64?
    var quietTicks = 0
    var observedPeak = previous.footprint
    let startFootprint = previous.footprint
    let startPeak = previous.peakFootprint

    while true {
        usleep(250_000)
        guard let current = readUsage(pid) else { fail("process \(pid) went away") }
        let now = nowNanoseconds()
        let percent = Double(current.cpuNanoseconds &- previous.cpuNanoseconds) / Double(now - previousTime) * 100
        observedPeak = max(observedPeak, current.footprint)
        previous = current
        previousTime = now
        let elapsed = milliseconds(from: begun, to: now) / 1000

        if percent > 25 {
            if firstBusy == nil { firstBusy = now }
            lastBusy = now
            quietTicks = 0
        } else {
            quietTicks += 1
        }
        let finished = firstBusy != nil && quietTicks >= 6 && elapsed >= minSeconds
        if finished || elapsed >= maxSeconds {
            guard let firstBusy, let lastBusy else {
                fail("scan never started (no busy period within \(Int(elapsed)) s)")
            }
            emit([
                "busyMs": milliseconds(from: firstBusy, to: lastBusy),
                "startedAfterMs": milliseconds(from: begun, to: firstBusy),
                "timedOut": !finished,
                "footprintAtStartBytes": Int(startFootprint),
                "lifetimePeakAtStartBytes": Int(startPeak),
                "footprintAtEndBytes": Int(current.footprint),
                "lifetimePeakAtEndBytes": Int(current.peakFootprint),
                "observedPeakBytes": Int(observedPeak),
            ])
        }
        if elapsed >= startTimeout, firstBusy == nil {
            fail("scan never started (no busy period within \(Int(elapsed)) s)")
        }
    }
}

/// Waits until the process has used under 5% of one core for 5 seconds in a row, and reports how long
/// it was active after the call and how much CPU time it had used by then (since process start).
func settle(_ arguments: Arguments) -> Never {
    guard let rawString = arguments.positional.first, let pid = Int32(rawString) else { fail("settle needs a pid") }
    let maxSeconds = arguments.number("max", default: 120)
    guard var previous = readUsage(pid) else { fail("cannot read process \(pid)") }
    let begun = nowNanoseconds()
    var previousTime = begun
    var lastActive = begun
    var cpuAtLastActive = previous.cpuNanoseconds
    var quietPolls = 0
    var observedPeak = previous.footprint
    while true {
        usleep(500_000)
        guard let current = readUsage(pid) else { fail("process \(pid) went away") }
        let now = nowNanoseconds()
        let percent = Double(current.cpuNanoseconds &- previous.cpuNanoseconds) / Double(now - previousTime) * 100
        observedPeak = max(observedPeak, current.footprint)
        if percent >= 5 {
            lastActive = now
            cpuAtLastActive = current.cpuNanoseconds
            quietPolls = 0
        } else {
            quietPolls += 1
        }
        previous = current
        previousTime = now
        let timedOut = milliseconds(from: begun, to: now) / 1000 >= maxSeconds
        if quietPolls >= 10 || timedOut {
            emit([
                "activeMs": milliseconds(from: begun, to: lastActive),
                "cpuSecondsUntilQuiet": Double(cpuAtLastActive) / 1e9,
                "timedOut": timedOut,
                "footprintBytes": Int(current.footprint),
                "peakFootprintBytes": Int(current.peakFootprint),
                "observedPeakBytes": Int(observedPeak),
            ])
        }
    }
}

func quit(_ arguments: Arguments) -> Never {
    guard arguments.positional.count == 2, let pid = Int32(arguments.positional[0]) else {
        fail("quit needs <pid> <app>")
    }
    guard let executable = appExecutable(arguments.positional[1]) else { fail("cannot read the app") }
    guard let actual = executablePath(of: pid) else { emit(["quit": "already gone"]) }
    guard actual == executable else { fail("pid \(pid) runs \(actual), not the app; not touching it") }
    kill(pid, SIGTERM)
    for _ in 0..<100 {
        usleep(50_000)
        if executablePath(of: pid) != executable { emit(["quit": "terminated"]) }
    }
    kill(pid, SIGKILL)
    usleep(300_000)
    if executablePath(of: pid) == executable { fail("pid \(pid) did not exit") }
    emit(["quit": "killed"])
}

// MARK: Sample analysis

/// One node of the call graph printed by `sample`.
struct Frame {
    var column: Int
    var count: Int
    var name: String
    var childTotal = 0
    var appFrame: String?
    /// True below a frame of accessibility-client code (XCTest snapshots, AXUIElement requests):
    /// another tool on the Mac is inspecting the app, which is not the app's own work.
    var external = false
}

/// Frames that only run when another process asks the app for its accessibility tree.
func isAccessibilityClientCode(_ name: String) -> Bool {
    ["XCTAutomationSupport", "_AXXMIG", "AXUIElement", "ccessibility"].contains { name.contains($0) }
}

/// Waiting leaves: the thread is blocked, not working.
func isWaiting(_ name: String) -> Bool {
    let prefixes = [
        "mach_msg", "semaphore_wait", "__ulock_wait", "__psynch_cvwait", "__psynch_mutexwait",
        "kevent", "__select", "__workq_kernreturn", "__semwait_signal", "poll",
    ]
    return prefixes.contains { name.hasPrefix($0) }
}

func analyze(_ arguments: Arguments) -> Never {
    guard let path = arguments.positional.first, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("analyze needs a readable sample file")
    }
    var inGraph = false
    var inMain = false
    var mainTotal = 0
    var busy = 0
    var external = 0
    var busyByWhere: [String: Int] = [:]
    var stack: [Frame] = []
    var timerHits: [String: Int] = [:]

    func close(_ frame: Frame) {
        guard inMain else { return }
        let own = frame.count - frame.childTotal
        if own > 0, !isWaiting(frame.name) {
            if frame.external {
                external += own
            } else {
                busy += own
                busyByWhere[frame.appFrame ?? frame.name, default: 0] += own
            }
        }
    }

    func flush() {
        while let frame = stack.popLast() { close(frame) }
    }

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("Call graph:") { inGraph = true; continue }
        guard inGraph else { continue }
        if line.hasPrefix("Total number in stack") || line.hasPrefix("Sort by top of stack") { break }

        let characters = Array(line)
        var column = 0
        while column < characters.count, " +!:|".contains(characters[column]) { column += 1 }
        guard column < characters.count, characters[column].isNumber else { continue }
        var end = column
        while end < characters.count, characters[end].isNumber { end += 1 }
        guard let count = Int(String(characters[column..<end])) else { continue }
        let name = shortName(String(characters[end...]))
        let isHeader = column == 4 && !characters[..<column].contains(where: { "+!:|".contains($0) })

        if isHeader {
            flush()
            inMain = name.contains("com.apple.main-thread") || name.contains(": Main Thread")
            if inMain { mainTotal += count }
            stack = []
            continue
        }

        while let top = stack.last, top.column >= column {
            stack.removeLast()
            close(top)
        }
        if !stack.isEmpty { stack[stack.count - 1].childTotal += count }
        var frame = Frame(column: column, count: count, name: name)
        let isAppCode = name.contains("(in TruongCleaner)") && !name.hasPrefix("main ")
        frame.appFrame = isAppCode ? name : stack.last?.appFrame
        frame.external = (stack.last?.external ?? false) || isAccessibilityClientCode(name)
        stack.append(frame)

        if name.range(of: "timer", options: .caseInsensitive) != nil {
            timerHits[name, default: 0] += count
        }
    }
    flush()

    let top = busyByWhere.sorted { $0.value > $1.value }.prefix(5).map { ["frame": $0.key, "samples": $0.value] as [String: Any] }
    let timers = timerHits.sorted { $0.value > $1.value }.prefix(5).map { ["frame": $0.key, "samples": $0.value] as [String: Any] }
    emit([
        "mainThreadSamples": mainTotal,
        "mainThreadBusySamples": busy,
        "mainThreadExternalSamples": external,
        "mainThreadBusyShare": mainTotal > 0 ? Double(busy) / Double(mainTotal) : 0,
        "topBusyFrames": top,
        "timerFrames": timers,
    ])
}

/// Drops the offset and address that `sample` appends to a frame.
func shortName(_ name: String) -> String {
    name
        .replacingOccurrences(of: #"\s+\[0x[0-9a-fA-F]+\].*$"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\s+\+\s+\d+\s*$"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

// MARK: Entry

@main
struct BenchTool {
    static func main() {
        var raw = Array(CommandLine.arguments.dropFirst())
        guard !raw.isEmpty else { fail("usage: benchtool launch|usage|watch|settle|quit|analyze ...") }
        let command = raw.removeFirst()
        let arguments = Arguments(raw)
        switch command {
        case "launch": launch(arguments)
        case "usage": usage(arguments)
        case "watch": watch(arguments)
        case "settle": settle(arguments)
        case "quit": quit(arguments)
        case "analyze": analyze(arguments)
        default: fail("unknown subcommand \(command)")
        }
    }
}
