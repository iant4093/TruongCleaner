import CleanerCore
import CleanerScanner
import Foundation

/// `tcbench scan-demo <home>`: runs three built-in rules through `ScanEngine` against a home folder
/// and prints totals and timing. Read-only: nothing is moved or deleted.
enum ScanDemoCommand {
    private static let usage = """
        usage: tcbench scan-demo <home>

        Scans <home>/Library/Caches (children), <home>/Library/Logs (log files older than 7 days) and
        <home>/Library/Developer/Xcode/DerivedData (children) with ScanEngine. Read-only.
        """

    static func run(_ arguments: [String]) async {
        guard arguments.count == 1, !arguments[0].hasPrefix("--") else { fail(usage) }
        let home = URL(filePath: arguments[0], directoryHint: .isDirectory)
        let request = ScanRequest(rules: rules, environment: Environment(home: home))

        let engine = ScanEngine()
        let clock = ContinuousClock()
        let started = clock.now
        var progressEvents = 0
        var lastFiles = 0
        var report: ScanReport?
        for await event in await engine.scan(request) {
            switch event {
            case .ruleStarted, .ruleFinished:
                break
            case .progress(let files, _):
                progressEvents += 1
                lastFiles = files
            case .finished(let final):
                report = final
            }
        }
        let wall = started.duration(to: clock.now)
        guard let report else { fail("scan ended without a report") }

        print("home                  \(home.path)")
        for result in report.results {
            print("\n\(result.ruleID)")
            print("  findings            \(result.findings.count)")
            print("  allocated           \(result.measuredBytes) bytes (\(ByteFormatter.string(result.measuredBytes)))")
            print("  private             \(ByteFormatter.string(result.measuredPrivateBytes))")
            print("  skipped             \(skipped(result.skippedCounts))")
            print("  needs access        \(result.needsAccess.count)")
            print("  missing roots       \(result.missingRoots.count)")
            print("  partial             \(result.partial)")
            print("  seconds             \(seconds(result.duration))")
            for finding in result.findings.sorted(by: { $0.allocatedBytes > $1.allocatedBytes }).prefix(3) {
                print("    \(ByteFormatter.string(finding.allocatedBytes))  \(finding.url.lastPathComponent)")
            }
        }
        print("\nduplicates dropped    \(report.duplicatesDropped)")
        print("progress events       \(progressEvents) (last: \(lastFiles) files)")
        print("engine seconds        \(seconds(report.duration))")
        print("wall seconds          \(seconds(wall))")
        print("peak memory           \(ByteFormatter.string(Int64(peakResidentBytes())))")
        print("partial               \(report.partial)")
    }

    private static var rules: [Rule] {
        func rule(
            _ id: String, _ components: [String], match: MatchSpec, depth: Int = 1, guards: Guards = Guards()
        ) -> Rule {
            Rule(
                id: id,
                category: .caches,
                tier: .safe,
                roots: [RootSpec(base: .home, components: components)],
                match: match,
                depth: depth,
                guards: guards,
                access: .user,
                action: .trash,
                title: "\(id)",
                explain: "Demo rule."
            )
        }
        return [
            rule("demo.caches", ["Library", "Caches"], match: .children),
            rule(
                "demo.logs", ["Library", "Logs"],
                match: .files(extensions: ["log", "txt", "ips", "crash", "diag"]), depth: 3,
                guards: Guards(minAge: .seconds(7 * 86_400))),
            rule("demo.xcodeDerivedData", ["Library", "Developer", "Xcode", "DerivedData"], match: .children),
        ]
    }

    private static func skipped(_ counts: [SkipReason: Int]) -> String {
        if counts.isEmpty { return "none" }
        return counts.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", ")
    }

    private static func seconds(_ duration: Duration) -> String {
        let parts = duration.components
        return String(format: "%.3f", Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }
}
