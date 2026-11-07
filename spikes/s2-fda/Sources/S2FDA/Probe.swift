import Darwin
import Foundation

// MARK: - Specs

/// How a probe touches its path.
enum ProbeKind: Sendable {
    /// `opendir` + `readdir` of one entry.
    case directory
    /// `open(O_RDONLY)` + `read` of one byte.
    case file
    /// List the directory, then `opendir` + `readdir` each child and count the results.
    case directoryChildren

    var method: String {
        switch self {
        case .directory: "opendir+readdir"
        case .file: "open+read(1)"
        case .directoryChildren: "list + opendir each child"
        }
    }
}

/// One path to test.
struct ProbeSpec: Sendable {
    let url: URL
    let kind: ProbeKind
    /// Dropped from the table when the path does not exist (`ENOENT`).
    let isOptional: Bool
    /// Counts toward the combined verdict (Safari, Mail, Messages, Stocks).
    let countsForVerdict: Bool
}

enum ProbeCatalog {
    /// The fixed probe list from the brief. Paths are built from URL components.
    static func specs(home: URL) -> [ProbeSpec] {
        func homePath(_ parts: String..., kind: ProbeKind = .directory,
                      optional: Bool = false, verdict: Bool = false) -> ProbeSpec {
            ProbeSpec(url: parts.reduce(home) { $0.appending(component: $1) }, kind: kind,
                      isOptional: optional, countsForVerdict: verdict)
        }
        func absolute(_ parts: String..., kind: ProbeKind) -> ProbeSpec {
            ProbeSpec(url: parts.reduce(URL(filePath: "/")) { $0.appending(component: $1) }, kind: kind,
                      isOptional: false, countsForVerdict: false)
        }
        return [
            homePath("Library", "Safari", verdict: true),
            homePath("Library", "Safari", "Bookmarks.plist", kind: .file, verdict: true),
            homePath("Library", "Mail", verdict: true),
            homePath("Library", "Messages", verdict: true),
            homePath("Library", "Containers", "com.apple.stocks", verdict: true),
            homePath("Library", "Containers", "com.apple.mail", "Data", "Library", "Mail Downloads"),
            homePath("Library", "Application Support", "MobileSync", "Backup"),
            homePath(".Trash"),
            homePath("Library", "Application Support", "com.apple.TCC", "TCC.db", kind: .file),
            absolute("Library", "Application Support", "com.apple.TCC", "TCC.db", kind: .file),
            absolute("Library", "Preferences", "com.apple.TimeMachine.plist", kind: .file),
            homePath("Library", "Containers", kind: .directoryChildren),
            homePath("Library", "Group Containers", kind: .directoryChildren),
            homePath("Library", "Application Support", "Google", "Chrome", optional: true),
            homePath("Library", "Application Support", "discord", optional: true)
        ]
    }
}

// MARK: - Outcomes

/// Result of one low-level read attempt.
enum ProbeOutcome: Sendable, Equatable {
    case readable
    case failed(errno: Int32)

    var label: String {
        switch self {
        case .readable: "readable"
        case .failed(let code): Self.name(of: code)
        }
    }

    var isDenied: Bool {
        self == .failed(errno: EPERM) || self == .failed(errno: EACCES)
    }

    var isMissing: Bool { self == .failed(errno: ENOENT) }

    private static func name(of code: Int32) -> String {
        switch code {
        case EPERM: "EPERM"
        case EACCES: "EACCES"
        case ENOENT: "ENOENT"
        case ENOTDIR: "ENOTDIR"
        case ELOOP: "ELOOP"
        case EIO: "EIO"
        default: "errno \(code) (\(String(cString: strerror(code))))"
        }
    }
}

/// One row in the table.
struct ProbeResult: Sendable, Identifiable {
    let id: Int
    let displayPath: String
    let method: String
    let outcome: ProbeOutcome
    /// Extra text, such as "12 readable, 30 denied of 42".
    let detail: String?
    let milliseconds: Double
    let countsForVerdict: Bool

    var resultText: String {
        guard let detail else { return outcome.label }
        return "\(outcome.label) (\(detail))"
    }
}

/// Combined answer from the Safari, Mail, Messages and Stocks probes.
enum FDAVerdict: String, Sendable {
    case granted
    case notGranted
    case unknown
}

/// All rows from one run plus the verdict.
struct ProbeReport: Sendable {
    let results: [ProbeResult]
    let date: Date
    let verdict: FDAVerdict

    static func verdict(for results: [ProbeResult]) -> FDAVerdict {
        let relevant = results.filter(\.countsForVerdict)
        if relevant.contains(where: { $0.outcome == .readable }) { return .granted }
        let existing = relevant.filter { !$0.outcome.isMissing }
        if !existing.isEmpty, existing.allSatisfy({ $0.outcome.isDenied }) { return .notGranted }
        return .unknown
    }

    /// Plain-text table used by "Copy Results" and `--cli`.
    func plainText() -> String {
        let process = ProcessInfo.processInfo
        var lines = [
            "S2FDA probe run \(date.formatted(.iso8601))",
            "macOS \(process.operatingSystemVersionString)",
            "Executable: \(Bundle.main.executablePath ?? process.arguments.first ?? "unknown")",
            "Verdict: \(verdict.rawValue)",
            ""
        ]
        let header = ["Path", "Method", "Result", "ms"]
        let rows = results.map { [$0.displayPath, $0.method, $0.resultText,
                                  String(format: "%.2f", $0.milliseconds)] }
        let widths = (0..<header.count).map { column in
            ([header] + rows).map { $0[column].count }.max() ?? 0
        }
        func format(_ row: [String]) -> String {
            row.enumerated().map { index, cell in
                index == row.count - 1
                    ? String(repeating: " ", count: max(0, widths[index] - cell.count)) + cell
                    : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
        lines.append(format(header))
        lines.append(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
        lines.append(contentsOf: rows.map(format))
        return lines.joined(separator: "\n")
    }
}

// MARK: - Low-level reads (read-only)

enum ProbeIO {
    /// `opendir` + `readdir` of the first real entry. An empty directory counts as readable.
    static func readFirstEntry(ofDirectoryAt path: String) -> ProbeOutcome {
        guard let dir = opendir(path) else { return .failed(errno: errno) }
        defer { closedir(dir) }
        errno = 0
        while let entry = readdir(dir) {
            if !isDotEntry(entry) { return .readable }
        }
        let code = errno
        return code == 0 ? .readable : .failed(errno: code)
    }

    /// `open(O_RDONLY)` + `read` of one byte. An empty file counts as readable.
    static func readFirstByte(ofFileAt path: String) -> ProbeOutcome {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return .failed(errno: errno) }
        defer { close(descriptor) }
        var byte: UInt8 = 0
        let count = read(descriptor, &byte, 1)
        return count < 0 ? .failed(errno: errno) : .readable
    }

    /// Lists a directory, then tries to read one entry of each child.
    static func listAndProbeChildren(ofDirectoryAt url: URL) -> (ProbeOutcome, String?) {
        let path = url.path(percentEncoded: false)
        guard let dir = opendir(path) else { return (.failed(errno: errno), nil) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(dir) {
            if !isDotEntry(entry) { names.append(entryName(entry)) }
        }
        let listingError = errno
        closedir(dir)
        if listingError != 0 { return (.failed(errno: listingError), nil) }

        var readable = 0
        var denied = 0
        var other = 0
        for name in names {
            let child = url.appending(component: name).path(percentEncoded: false)
            let outcome = readFirstEntry(ofDirectoryAt: child)
            if outcome == .readable {
                readable += 1
            } else if outcome.isDenied {
                denied += 1
            } else {
                other += 1
            }
        }
        let detail = "\(names.count) children: \(readable) readable, \(denied) denied, \(other) other"
        return (.readable, detail)
    }

    private static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        let nameField = entry.pointee.d_name
        return withUnsafeBytes(of: nameField) { bytes in
            let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
    }

    private static func isDotEntry(_ entry: UnsafeMutablePointer<dirent>) -> Bool {
        let name = entryName(entry)
        return name == "." || name == ".."
    }
}

// MARK: - Runner

enum ProbeRunner {
    /// Runs every probe once. Blocking; call from a background context.
    static func runBlocking() -> ProbeReport {
        let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
        let homePath = home.path(percentEncoded: false).trimmingSuffix("/")
        var results: [ProbeResult] = []

        for spec in ProbeCatalog.specs(home: home) {
            let path = spec.url.path(percentEncoded: false)
            let clock = ContinuousClock()
            let start = clock.now
            let outcome: ProbeOutcome
            var detail: String?
            switch spec.kind {
            case .directory:
                outcome = ProbeIO.readFirstEntry(ofDirectoryAt: path)
            case .file:
                outcome = ProbeIO.readFirstByte(ofFileAt: path)
            case .directoryChildren:
                (outcome, detail) = ProbeIO.listAndProbeChildren(ofDirectoryAt: spec.url)
            }
            let elapsed = start.duration(to: clock.now)
            let milliseconds = Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1e15

            if spec.isOptional && outcome.isMissing { continue }
            let display = path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
            results.append(ProbeResult(
                id: results.count,
                displayPath: display,
                method: spec.kind.method,
                outcome: outcome,
                detail: detail,
                milliseconds: milliseconds,
                countsForVerdict: spec.countsForVerdict
            ))
        }
        return ProbeReport(results: results, date: Date(), verdict: ProbeReport.verdict(for: results))
    }

    /// Runs the probes off the main actor.
    @concurrent
    static func run() async -> ProbeReport {
        runBlocking()
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
