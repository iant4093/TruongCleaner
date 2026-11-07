import Foundation
import Testing
@testable import CleanerScanner

struct APFSListParserTests {
    private func containers() throws -> [APFSContainer] {
        try APFSListParser.parse(plist: Data(SystemSamples.diskutilAPFSList.utf8))
    }

    @Test func readsEveryContainerAndVolume() throws {
        let containers = try containers()
        #expect(containers.map(\.reference) == ["disk1", "disk3", "disk5"])

        let startup = try #require(containers.first { $0.reference == "disk3" })
        #expect(startup.volumes.count == 6)
        let data = try #require(startup.volumes.first { $0.roles == ["Data"] })
        #expect(data.name == "Macintosh HD - Data")
        #expect(data.bytesUsed == 904_122_363_904)
        let system = try #require(startup.volumes.first { $0.roles == ["System"] })
        #expect(system.bytesUsed == 13_653_516_288)
    }

    @Test func keepsVolumesWithNoRoles() throws {
        let simulator = try #require(containers().first { $0.reference == "disk5" })
        #expect(simulator.volumes.first?.roles == [])
    }

    @Test func readsTheContainerReferenceFromDiskutilInfo() throws {
        let reference = try APFSListParser.containerReference(infoPlist: Data(SystemSamples.diskutilInfoRoot.utf8))
        #expect(reference == "disk3")
    }

    @Test func picksTheContainerNamedByInfo() throws {
        let all = try containers()
        #expect(APFSListParser.startupContainer(in: all, reference: "disk5")?.reference == "disk5")
        #expect(APFSListParser.startupContainer(in: all, reference: "disk99") == nil)
    }

    @Test func fallsBackToTheOnlyContainerWithADataVolume() throws {
        let all = try containers()
        #expect(APFSListParser.startupContainer(in: all, reference: nil)?.reference == "disk3")
    }

    @Test func doesNotGuessWhenTwoContainersHaveDataVolumes() throws {
        let data = APFSVolumeUsage(name: "Data", roles: ["Data"], bytesUsed: 1)
        let two = [
            APFSContainer(reference: "disk1", volumes: [data]),
            APFSContainer(reference: "disk2", volumes: [data]),
        ]
        #expect(APFSListParser.startupContainer(in: two, reference: nil) == nil)
    }

    @Test(arguments: [
        "",
        "not a plist at all",
        "<?xml version=\"1.0\"?><plist version=\"1.0\"><array/></plist>",
        "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Other</key><string>x</string></dict></plist>",
    ])
    func malformedListIsAParseError(text: String) {
        let error = #expect(throws: ProbeError.self) {
            try APFSListParser.parse(plist: Data(text.utf8))
        }
        guard case .parse = error else {
            Issue.record("expected ProbeError.parse, got \(String(describing: error))")
            return
        }
    }

    @Test func malformedInfoIsAParseError() {
        #expect(throws: ProbeError.self) {
            try APFSListParser.containerReference(infoPlist: Data("garbage".utf8))
        }
        #expect(throws: ProbeError.self) {
            let plist = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>"
            return try APFSListParser.containerReference(infoPlist: Data(plist.utf8))
        }
    }
}
