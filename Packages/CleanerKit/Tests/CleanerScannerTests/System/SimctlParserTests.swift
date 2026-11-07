import Foundation
import Testing
@testable import CleanerScanner

struct SimctlParserTests {
    @Test func parsesDevicesFromRealOutput() throws {
        let devices = try SimctlParser.devices(json: Data(SystemSamples.simctlDevices.utf8))
        #expect(devices.count == 5)

        let pro = try #require(devices.first { $0.name == "iPhone 18 Pro" })
        #expect(pro.udid == "00000000-0000-4000-8000-000000000015")
        #expect(pro.runtimeID == "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        #expect(pro.state == "Shutdown")
        #expect(pro.isAvailable)
        #expect(pro.dataPath?.path == "/Users/example/Library/Developer/CoreSimulator/Devices/00000000-0000-4000-8000-000000000015/data")
        #expect(pro.lastBootedAt == Date(timeIntervalSince1970: 1_793_559_495))

        let air = try #require(devices.first { $0.name == "iPhone Air" })
        #expect(air.lastBootedAt == nil)
    }

    @Test func marksUnavailableDevices() throws {
        let devices = try SimctlParser.devices(json: Data(SystemSamples.simctlDevices.utf8))
        let old = try #require(devices.first { $0.name == "iPhone 15" })
        #expect(!old.isAvailable)
        #expect(old.runtimeID == "com.apple.CoreSimulator.SimRuntime.iOS-17-5")
    }

    @Test func acceptsOlderAvailabilityTextAndLastBootedAt() throws {
        let json = """
        {"devices": {"com.apple.CoreSimulator.SimRuntime.tvOS-18-0": [
          {"udid": "U1", "name": "Apple TV", "state": "Booted",
           "availability": "(available)", "lastBootedAt": "2026-03-04T05:06:07.250Z", "extra": {"x": 1}}
        ]}}
        """
        let device = try #require(SimctlParser.devices(json: Data(json.utf8)).first)
        #expect(device.isAvailable)
        #expect(device.state == "Booted")
        #expect(device.dataPath == nil)
        #expect(device.lastBootedAt != nil)
    }

    @Test func noDevicesIsAnEmptyList() throws {
        #expect(try SimctlParser.devices(json: Data(#"{"devices": {}}"#.utf8)).isEmpty)
    }

    @Test(arguments: ["", "garbage", "[]", #"{"devices": []}"#, #"{"devices": {"rt": [{"name": "no udid"}]}}"#, #"{"other": 1}"#])
    func malformedDevicesIsAParseError(text: String) {
        let error = #expect(throws: ProbeError.self) {
            try SimctlParser.devices(json: Data(text.utf8))
        }
        guard case .parse = error else {
            Issue.record("expected ProbeError.parse, got \(String(describing: error))")
            return
        }
    }

    @Test func parsesRuntimesFromRealOutput() throws {
        let runtimes = try SimctlParser.runtimes(json: Data(SystemSamples.simctlRuntimes.utf8))
        #expect(runtimes.count == 2)

        let ios = try #require(runtimes.first { $0.version == "27.0" })
        #expect(ios.identifier == "00000000-0000-4000-8000-000000000019")
        #expect(ios.name == "iOS 27.0")
        #expect(ios.sizeBytes == 8_067_000_161)
        #expect(ios.isDeletable == true)
        #expect(ios.lastUsedAt == Date(timeIntervalSince1970: 1_793_478_772))

        let watch = try #require(runtimes.first { $0.version == "12.0" })
        #expect(watch.name == "watchOS 12.0")
        #expect(watch.sizeBytes == nil)
        #expect(watch.lastUsedAt == nil)
        #expect(watch.isDeletable == false)
    }

    @Test func runtimeIdentifierFallsBackToTheKey() throws {
        let runtimes = try SimctlParser.runtimes(json: Data(#"{"KEY-1": {"version": "1.0"}}"#.utf8))
        let runtime = try #require(runtimes.first)
        #expect(runtime.identifier == "KEY-1")
        #expect(runtime.name == "KEY-1")
        #expect(runtime.isDeletable == nil)
    }

    @Test func noRuntimesIsAnEmptyList() throws {
        #expect(try SimctlParser.runtimes(json: Data("{}".utf8)).isEmpty)
    }

    @Test(arguments: ["", "garbage", "[]", #"{"a": 1}"#, #"{"a": {"sizeBytes": "big"}}"#])
    func malformedRuntimesIsAParseError(text: String) {
        let error = #expect(throws: ProbeError.self) {
            try SimctlParser.runtimes(json: Data(text.utf8))
        }
        guard case .parse = error else {
            Issue.record("expected ProbeError.parse, got \(String(describing: error))")
            return
        }
    }
}
