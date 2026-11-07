import Foundation

/// One local APFS snapshot.
public struct LocalSnapshot: Sendable, Hashable {
    /// The snapshot name as `tmutil` prints it.
    public let name: String
    /// When the snapshot was taken, if the name or `tmutil` says so.
    public let date: Date?
    /// `true` for `com.apple.TimeMachine.<date>.local` snapshots; `false` for any other name.
    public let isTimeMachine: Bool

    /// Creates a snapshot value.
    public init(name: String, date: Date?, isTimeMachine: Bool) {
        self.name = name
        self.date = date
        self.isTimeMachine = isTimeMachine
    }
}

/// Reads local APFS snapshots with `tmutil` (list verbs only; works as the current user).
public enum Snapshots {
    /// Lists local snapshots of the startup volume.
    ///
    /// Zero snapshots is a success with an empty array. Any failure is an error, never an empty list.
    public static func list() async -> Result<[LocalSnapshot], ProbeError> {
        async let names = ReadOnlyCommand.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: .seconds(15))
        async let dates = ReadOnlyCommand.run("/usr/bin/tmutil", ["listlocalsnapshotdates", "/"], timeout: .seconds(15))
        let (namesResult, datesResult) = await (names, dates)

        if let failure = namesResult.probeError(tool: "tmutil") { return .failure(failure) }
        // The dates list only refines dates. If it fails, dates come from the names.
        let datesOutput = datesResult.succeeded ? datesResult.stdoutString : nil
        do {
            let snapshots = try SnapshotParser.parse(listOutput: namesResult.stdoutString, datesOutput: datesOutput)
            return .success(snapshots)
        } catch {
            return .failure(error)
        }
    }
}

/// Parses `tmutil listlocalsnapshots /` and `tmutil listlocalsnapshotdates /` output.
enum SnapshotParser {
    private static let listHeaderPrefix = "Snapshots for "
    private static let datesHeaderPrefix = "Snapshot dates for "
    private static let timeMachinePrefix = "com.apple.TimeMachine."

    /// - Parameters:
    ///   - listOutput: Output of `tmutil listlocalsnapshots /`. A header line is required.
    ///   - datesOutput: Output of `tmutil listlocalsnapshotdates /`, or `nil` when unavailable.
    ///   - timeZone: Zone of the `yyyy-MM-dd-HHmmss` stamps (they are local time).
    /// - Throws: ``ProbeError/parse(_:)`` when the output has no header line.
    static func parse(
        listOutput: String,
        datesOutput: String?,
        timeZone: TimeZone = .current
    ) throws(ProbeError) -> [LocalSnapshot] {
        let listLines = lines(of: listOutput)
        guard let header = listLines.first, header.hasPrefix(listHeaderPrefix) else {
            throw .parse("tmutil snapshot list has no \"Snapshots for\" header")
        }

        // Stamp text -> date, from the dates command when it printed a valid list.
        var knownDates: [String: Date] = [:]
        if let datesOutput {
            let dateLines = lines(of: datesOutput)
            if let first = dateLines.first, first.hasPrefix(datesHeaderPrefix) {
                for line in dateLines.dropFirst() {
                    if let date = date(fromStamp: line, timeZone: timeZone) { knownDates[line] = date }
                }
            }
        }

        return listLines.dropFirst().map { name in
            let stamp = timestamp(in: name)
            let date = stamp.flatMap { knownDates[$0] ?? date(fromStamp: $0, timeZone: timeZone) }
            let isTimeMachine = name.hasPrefix(timeMachinePrefix) && stamp != nil
            return LocalSnapshot(name: name, date: date, isTimeMachine: isTimeMachine)
        }
    }

    private static func lines(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Finds the first `yyyy-MM-dd-HHmmss` stamp in a string.
    private static func timestamp(in text: String) -> String? {
        text.firstMatch(of: /\d{4}-\d{2}-\d{2}-\d{6}/).map { String($0.output) }
    }

    private static func date(fromStamp stamp: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: stamp)
    }
}
