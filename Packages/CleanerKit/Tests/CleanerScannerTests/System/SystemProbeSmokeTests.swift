import Foundation
import Testing
@testable import CleanerScanner

/// Live checks against this Mac. They only read.
struct SystemProbeSmokeTests {
    @Test func volumeInfoHasSaneNumbers() async {
        let info = await VolumeInfo.current()
        #expect(info.total > 0)
        #expect(info.available > 0)
        #expect(info.available <= info.total)
        #expect(info.purgeable >= 0)
        #expect(info.containerUsed == info.total - info.available)
        #expect(info.availableForImportantUsage >= 0)
        if let dataUsed = info.dataVolumeUsed {
            #expect(dataUsed > 0 && dataUsed <= info.total)
        }
        // Volumes are optional (diskutil may be unavailable) but, when present, one is the Data volume.
        if !info.volumes.isEmpty {
            #expect(info.volumes.contains { $0.roles.contains("Data") })
            #expect(info.volumes.map(\.bytesUsed).reduce(0, +) <= info.total)
        }
    }

    @Test func purgeableNeverGoesNegative() {
        let info = VolumeInfo(
            total: 1000, available: 400, availableForImportantUsage: 300,
            availableForOpportunisticUsage: 300, dataVolumeUsed: nil, volumes: []
        )
        #expect(info.purgeable == 0)
        #expect(info.containerUsed == 600)

        let normal = VolumeInfo(
            total: 1000, available: 400, availableForImportantUsage: 650,
            availableForOpportunisticUsage: 600, dataVolumeUsed: 500, volumes: []
        )
        #expect(normal.purgeable == 250)
    }

    @Test func dataVolumeUsedIsReadable() {
        let used = VolumeInfo.spaceUsed(path: "/System/Volumes/Data")
        #expect(used != nil)
        #expect(VolumeInfo.spaceUsed(path: "/nonexistent/path") == nil)
    }

    @Test func swapProbeAnswers() throws {
        let swap = try #require(SwapProbe.current())
        #expect(swap.total >= 0)
        #expect(swap.used >= 0)
        #expect(swap.used <= swap.total)
        #expect(swap.free >= 0)
    }

    @Test func snapshotListIsNeverAParseFailure() async {
        let result = await Snapshots.list()
        if case .failure(.parse(let message)) = result {
            Issue.record("could not parse real tmutil output: \(message)")
        }
    }

    @Test func simulatorListsAreNeverParseFailures() async {
        if case .failure(.parse(let message)) = await Simulators.devices() {
            Issue.record("could not parse real simctl devices output: \(message)")
        }
        if case .failure(.parse(let message)) = await Simulators.runtimes() {
            Issue.record("could not parse real simctl runtime output: \(message)")
        }
    }
}
