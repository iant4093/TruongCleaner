import CleanerCore
import CleanerScanner
import Foundation

/// `tcbench categories <home>`: measures the Data volume's categories with `CategoryScanner` and prints
/// each one with timing. Read-only: nothing is moved or deleted.
enum CategoriesCommand {
    private static let usage = """
        usage: tcbench categories <home> [--no-system]

        Measures Applications, Documents, Downloads, Desktop, Pictures, Movies, Music, iCloud Drive,
        Library caches and other Library data, Developer, iOS backups, Mail, Messages, Trash and the rest
        of <home>, plus other users under /Users. Read-only.
          --no-system   skip /Applications and /Users
        """

    static func run(_ arguments: [String]) async {
        var home: String?
        var includeSystem = true
        for argument in arguments {
            switch argument {
            case "--no-system":
                includeSystem = false
            default:
                guard home == nil, !argument.hasPrefix("--") else { fail("unexpected argument: \(argument)\n\n\(usage)") }
                home = argument
            }
        }
        guard let home else { fail(usage) }
        let url = URL(filePath: home, directoryHint: .isDirectory)

        let clock = ContinuousClock()
        let started = clock.now
        let totals: CategoryTotals
        if includeSystem {
            totals = await CategoryScanner.measure(home: url)
        } else {
            totals = await CategoryScanner.measure(home: url, applicationsRoot: nil, usersRoot: nil)
        }
        let wall = started.duration(to: clock.now)

        print("home                  \(url.path)")
        for category in StorageCategory.allCases {
            let bytes = totals.bytes(of: category)
            let name = category.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)
            let size = ByteFormatter.string(bytes).padding(toLength: 12, withPad: " ", startingAt: 0)
            let exclusive = ByteFormatter.string(totals.privateBytes[category] ?? 0)
            var line = "  \(name) \(size) private \(exclusive.padding(toLength: 12, withPad: " ", startingAt: 0))"
            let denied = totals.needsAccess[category] ?? 0
            if denied > 0 { line += "  needs access: \(denied)" }
            print(line)
        }
        print("total allocated       \(totals.totalBytes) bytes (\(ByteFormatter.string(totals.totalBytes)))")
        print("total private         \(totals.totalPrivateBytes) bytes (\(ByteFormatter.string(totals.totalPrivateBytes)))")
        print("needs access          \(totals.totalNeedsAccess)")
        print("measure seconds       \(String(format: "%.3f", seconds(totals.duration)))")
        print("wall seconds          \(String(format: "%.3f", seconds(wall)))")
        print("peak memory           \(ByteFormatter.string(Int64(peakResidentBytes())))")
        print("partial               \(totals.partial)")
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
