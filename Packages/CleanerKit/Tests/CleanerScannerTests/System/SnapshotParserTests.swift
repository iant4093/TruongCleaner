import Foundation
import Testing
@testable import CleanerScanner

struct SnapshotParserTests {
    private let utc = TimeZone(identifier: "UTC") ?? .gmt

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ))
    }

    @Test func headerOnlyMeansZeroSnapshots() throws {
        let snapshots = try SnapshotParser.parse(
            listOutput: SystemSamples.tmutilListEmpty,
            datesOutput: SystemSamples.tmutilDatesEmpty,
            timeZone: utc
        )
        #expect(snapshots.isEmpty)
    }

    @Test func parsesThreeTimeMachineSnapshotsAndOneOther() throws {
        let snapshots = try SnapshotParser.parse(
            listOutput: SystemSamples.tmutilListFour,
            datesOutput: SystemSamples.tmutilDatesThree,
            timeZone: utc
        )
        #expect(snapshots.count == 4)
        #expect(snapshots.filter(\.isTimeMachine).count == 3)

        let first = try #require(snapshots.first)
        #expect(first.name == "com.apple.TimeMachine.2026-11-03-091500.local")
        #expect(first.isTimeMachine)
        #expect(first.date == date(2026, 11, 3, 9, 15, 0))

        let last = try #require(snapshots.last)
        #expect(last.name == "com.example.backup-tool.snapshot-42")
        #expect(!last.isTimeMachine)
        #expect(last.date == nil)
    }

    @Test func datesComeFromNamesWhenTheDatesCommandIsMissing() throws {
        let snapshots = try SnapshotParser.parse(
            listOutput: SystemSamples.tmutilListFour, datesOutput: nil, timeZone: utc
        )
        #expect(snapshots.count == 4)
        #expect(snapshots[1].date == date(2026, 11, 4, 10, 15, 0))
    }

    @Test func aNonTimeMachineNameWithAStampKeepsItsDateButIsNotTimeMachine() throws {
        let output = "Snapshots for disk /:\nsome.tool.2026-01-02-030405\n"
        let snapshots = try SnapshotParser.parse(listOutput: output, datesOutput: nil, timeZone: utc)
        let snapshot = try #require(snapshots.first)
        #expect(!snapshot.isTimeMachine)
        #expect(snapshot.date == date(2026, 1, 2, 3, 4, 5))
    }

    @Test func garbageIsAParseErrorNotACrash() {
        let error = #expect(throws: ProbeError.self) {
            try SnapshotParser.parse(listOutput: SystemSamples.tmutilGarbage, datesOutput: nil, timeZone: utc)
        }
        guard case .parse = error else {
            Issue.record("expected ProbeError.parse, got \(String(describing: error))")
            return
        }
    }

    @Test func emptyOutputIsAParseError() {
        #expect(throws: ProbeError.self) {
            try SnapshotParser.parse(listOutput: "", datesOutput: nil, timeZone: utc)
        }
    }

    @Test func aBrokenDatesListIsIgnored() throws {
        let snapshots = try SnapshotParser.parse(
            listOutput: SystemSamples.tmutilListFour, datesOutput: SystemSamples.tmutilGarbage, timeZone: utc
        )
        #expect(snapshots.count == 4)
        #expect(snapshots[0].date == date(2026, 11, 3, 9, 15, 0))
    }
}
