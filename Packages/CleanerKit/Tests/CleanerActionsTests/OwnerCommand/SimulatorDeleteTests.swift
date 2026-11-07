import CleanerScanner
import CleanerTestSupport
import Foundation
import Testing

@testable import CleanerActions

struct SimulatorDeleteTests {
    private typealias Support = OwnerTestSupport

    private static let udid = "0F3A9C2E-5B7D-4E1A-9C6F-1D2B3A4C5D6E"
    private static let otherUDID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    private static let runtimeID = "7C1F2A3B-4D5E-6F70-8192-A3B4C5D6E7F8"

    // MARK: Validation

    @Test(arguments: [
        (udid, true),
        (otherUDID, true),
        (String(repeating: "-", count: 36), true),
        ("", false),
        ("0f3a9c2e-5b7d-4e1a-9c6f-1d2b3a4c5d6e", false),
        (String(udid.dropLast()), false),
        (udid + "A", false),
        (udid + "\n", false),
        ("\n" + udid, false),
        ("0F3A9C2E-5B7D-4E1A-9C6F-1D2B3A4C5D6G", false),
        ("../../../../../../../../../../../tmp/x", false),
        ("; rm -rf ~ ; rm -rf ~ ; rm -rf ~ ;;;;", false),
        ("unavailable", false),
        ("ＡＢ" + String(repeating: "A", count: 32), false),
    ])
    func udidValidation(text: String, valid: Bool) {
        #expect(OwnerCommandRunner.isValidUDID(text) == valid)
    }

    @Test(arguments: [
        ("com.apple.CoreSimulator.SimRuntime.iOS-27-0", true),
        (runtimeID, true),
        ("a", true),
        (String(repeating: "a", count: 128), true),
        (String(repeating: "a", count: 129), false),
        ("", false),
        ("-all", false),
        ("--help", false),
        ("a b", false),
        ("a/b", false),
        ("a;b", false),
        ("a\n", false),
        ("é", false),
        ("a$(id)", false),
    ])
    func runtimeIdentifierValidation(text: String, valid: Bool) {
        #expect(OwnerCommandRunner.isValidRuntimeIdentifier(text) == valid)
    }

    // MARK: Devices

    @Test func aKnownShutDeviceIsDeletedWithTheExactArgv() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "xcrun")
        let runner = Support.runner(
            [], xcrun: [tool.path],
            devices: .success([Support.device(Self.otherUDID, state: "Booted"), Support.device(Self.udid)])
        )

        let result = await runner.deleteSimulator(udid: Self.udid)

        #expect(result.id == .simctlDeleteDevice)
        #expect(result.skipped == nil)
        #expect(result.exitCode == 0)
        #expect(result.executable == tool.path)
        #expect(tool.records().map(\.arguments) == [["simctl", "delete", Self.udid]])
        #expect(tool.records().first?.environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin:" + tool.url.deletingLastPathComponent().path)
    }

    @Test(arguments: ["", "not-a-udid", "0f3a9c2e-5b7d-4e1a-9c6f-1d2b3a4c5d6e", "../x", "-----", "--all"])
    func aBadUDIDIsSkippedWithoutLaunching(udid: String) async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "xcrun")
        // Even a list that contains the bad string must not let it through.
        let runner = Support.runner([], xcrun: [tool.path], devices: .success([Support.device(udid)]))

        let result = await runner.deleteSimulator(udid: udid)

        #expect(result.skipped == "not a valid simulator ID")
        #expect(result.exitCode == nil)
        #expect(tool.records().isEmpty)
    }

    @Test func anUnknownDeviceIsSkipped() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "xcrun")
        let runner = Support.runner([], xcrun: [tool.path], devices: .success([Support.device(Self.otherUDID)]))

        let result = await runner.deleteSimulator(udid: Self.udid)

        #expect(result.skipped == "no simulator with that ID")
        #expect(tool.records().isEmpty)
    }

    @Test(arguments: ["Booted", "Booting", "Shutting Down", "Unknown"])
    func aDeviceThatIsNotShutDownIsSkipped(state: String) async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "xcrun")
        let runner = Support.runner([], xcrun: [tool.path], devices: .success([Support.device(Self.udid, state: state)]))

        let result = await runner.deleteSimulator(udid: Self.udid)

        #expect(result.skipped == "the simulator is not shut down")
        #expect(tool.records().isEmpty)
    }

    @Test func anUnreadableDeviceListMeansKeep() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "xcrun")
        let runner = Support.runner([], xcrun: [tool.path], devices: .failure(.toolMissing("xcrun")))

        let result = await runner.deleteSimulator(udid: Self.udid)

        #expect(result.skipped?.contains("could not list simulators") == true)
        #expect(tool.records().isEmpty)
    }

    @Test func aMissingXcrunIsSkipped() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let runner = Support.runner(
            [], xcrun: [tree.url(for: "bin/xcrun").path], devices: .success([Support.device(Self.udid)])
        )

        let result = await runner.deleteSimulator(udid: Self.udid)

        #expect(result.skipped == "tool not found")
    }

    // MARK: Runtimes

    @Test func aKnownRuntimeIsDeletedWithTheExactArgv() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "xcrun")
        let runner = Support.runner(
            [], xcrun: [tool.path],
            runtimes: .success([Support.runtime("other-1"), Support.runtime(Self.runtimeID)])
        )

        let result = await runner.deleteSimulatorRuntime(identifier: Self.runtimeID)

        #expect(result.id == .simctlDeleteRuntime)
        #expect(result.skipped == nil)
        #expect(result.exitCode == 0)
        #expect(tool.records().map(\.arguments) == [["simctl", "runtime", "delete", Self.runtimeID]])
    }

    @Test(arguments: ["", "-all", "--help", "a b", "a/../b", "x;y", "é", String(repeating: "a", count: 129)])
    func aBadRuntimeIdentifierIsSkippedWithoutLaunching(identifier: String) async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "xcrun")
        let runner = Support.runner([], xcrun: [tool.path], runtimes: .success([Support.runtime(identifier)]))

        let result = await runner.deleteSimulatorRuntime(identifier: identifier)

        #expect(result.skipped == "not a valid runtime identifier")
        #expect(tool.records().isEmpty)
    }

    @Test func anUnknownRuntimeIsSkipped() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "xcrun")
        let runner = Support.runner([], xcrun: [tool.path], runtimes: .success([Support.runtime("other-1")]))

        let result = await runner.deleteSimulatorRuntime(identifier: Self.runtimeID)

        #expect(result.skipped == "no runtime with that identifier")
        #expect(tool.records().isEmpty)
    }

    @Test func anUnreadableRuntimeListMeansKeep() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = try FakeTool.make(in: tree, folder: "bin", name: "xcrun")
        let runner = Support.runner([], xcrun: [tool.path], runtimes: .failure(.parse("bad")))

        let result = await runner.deleteSimulatorRuntime(identifier: Self.runtimeID)

        #expect(result.skipped?.contains("could not list runtimes") == true)
        #expect(tool.records().isEmpty)
    }
}
