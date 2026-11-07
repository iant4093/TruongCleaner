import CleanerCore
import CleanerScanner
import Darwin
import Foundation

/// `tcbench smartclean <home>`: scans the rules the Smart Clean page offers through `ScanEngine` and
/// prints totals and timing. Read-only: nothing is moved or deleted and no owner command runs.
///
/// The rule filter is the one in `SmartCleanModel.isOffered`: rules that act with the Trash and
/// Info rules that only measure. Owner-command rules and `trash.user` are left out, as in the app.
/// The app's Settings (turned-off rules, exclusions, project folders) are not read, so every
/// catalog rule is "enabled" and no folder is excluded.
enum SmartCleanCommand {
    private static let usage = """
        usage: tcbench smartclean <home> [--rules] [--roots n] [--workers n]

        Runs every rule that the Smart Clean page offers (see Catalog.all) through ScanEngine against
        <home>. Read-only.
          --rules     print one line per rule: seconds, findings, allocated bytes, private bytes
          --roots n   roots walked at once (default: the engine's default)
          --workers n most threads one root may use (default: the engine's default)
        """

    static func run(_ arguments: [String]) async {
        var listRules = false
        var roots: Int?
        var workers: Int?
        var paths: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--rules":
                listRules = true
                index += 1
            case "--roots", "--workers":
                guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value >= 1 else {
                    fail("\(argument) needs a number\n\n\(usage)")
                }
                if argument == "--roots" { roots = value } else { workers = value }
                index += 2
            default:
                guard !argument.hasPrefix("--") else { fail(usage) }
                paths.append(argument)
                index += 1
            }
        }
        guard paths.count == 1 else { fail(usage) }
        let home = URL(filePath: paths[0], directoryHint: .isDirectory)
        let rules = Catalog.all.filter(isOffered)
        let environment = Environment(
            home: home,
            darwinUserCache: darwinDirectory(_CS_DARWIN_USER_CACHE_DIR),
            darwinUserTemp: darwinDirectory(_CS_DARWIN_USER_TEMP_DIR)
        )
        var request = ScanRequest(rules: rules, environment: environment)
        if let roots { request.maxConcurrentRoots = roots }
        if let workers { request.workersPerRoot = workers }

        let engine = ScanEngine()
        let clock = ContinuousClock()
        let started = clock.now
        var lastFiles = 0
        var report: ScanReport?
        for await event in await engine.scan(request) {
            switch event {
            case .ruleStarted, .ruleFinished:
                break
            case .progress(let files, _):
                lastFiles = files
            case .finished(let final):
                report = final
            }
        }
        let wall = started.duration(to: clock.now)
        guard let report else { fail("scan ended without a report") }

        let findings = report.results.reduce(0) { $0 + $1.findings.count }
        let allocated = report.results.reduce(Int64(0)) { $0 + $1.measuredBytes }
        let privateBytes = report.results.reduce(Int64(0)) { $0 + $1.measuredPrivateBytes }
        let needsAccess = report.results.reduce(0) { $0 + $1.needsAccess.count }
        let tiers = Dictionary(grouping: rules, by: \.tier).mapValues(\.count)

        func line(_ name: String, _ value: String) {
            print("\(name.padding(toLength: 22, withPad: " ", startingAt: 0))\(value)")
        }
        line("home", home.path)
        line("rules", "\(rules.count) (safe \(tiers[.safe] ?? 0), review \(tiers[.review] ?? 0), info \(tiers[.info] ?? 0))")
        line("findings", "\(findings)")
        line("files counted", "\(lastFiles)")
        line("allocated bytes", "\(allocated)")
        line("private bytes", "\(privateBytes)")
        line("needs access", "\(needsAccess)")
        line("duplicates dropped", "\(report.duplicatesDropped)")
        line("partial", "\(report.partial)")
        line("engine seconds", seconds(report.duration))
        line("wall seconds", seconds(wall))
        line("peak memory bytes", "\(peakResidentBytes())")
        for result in report.results.sorted(by: { $0.duration > $1.duration }).prefix(5) {
            line("slow rule", "\(seconds(result.duration)) s  \(result.ruleID)")
        }
        if listRules {
            for result in report.results {
                line(
                    "rule", "\(seconds(result.duration)) s  \(result.findings.count) findings  "
                        + "\(result.measuredBytes) B  \(result.measuredPrivateBytes) B private  \(result.ruleID)")
            }
        }
    }

    /// Same decision as `SmartCleanModel.isOffered` in the app.
    private static func isOffered(_ rule: Rule) -> Bool {
        if case .ownerCommand = rule.match { return false }
        if rule.tier == .info {
            if case .measureOnly = rule.match { return true }
            return false
        }
        switch rule.action {
        case .trash:
            if case .measureOnly = rule.match { return false }
            return true
        case .deletePermanently, .ownerCommand, .none:
            return false
        }
    }

    /// The folder `confstr` names, or nil when it is not available.
    private static func darwinDirectory(_ name: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let needed = confstr(name, &buffer, buffer.count)
        guard needed > 0, needed <= buffer.count else { return nil }
        let path = buffer.withUnsafeBufferPointer { pointer in
            String(decoding: pointer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    private static func seconds(_ duration: Duration) -> String {
        let parts = duration.components
        return String(format: "%.3f", Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }
}
