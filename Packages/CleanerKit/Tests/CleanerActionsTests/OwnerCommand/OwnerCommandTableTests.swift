import Foundation
import Testing

@testable import CleanerActions

struct OwnerCommandTableTests {
    private struct Row {
        let id: String
        let candidates: [String]
        let arguments: [String]
        let seconds: Int64
        let preflight: Preflight
    }

    private static let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    private static let pnpm = ["/opt/homebrew/bin/pnpm", "/usr/local/bin/pnpm"]
    private static let go = ["/opt/homebrew/bin/go", "/usr/local/go/bin/go"]
    private static let docker = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"]

    private static let expected: [Row] = [
        Row(id: "simctl.deleteUnavailable", candidates: ["/usr/bin/xcrun"],
            arguments: ["simctl", "delete", "unavailable"], seconds: 120, preflight: .noBootedSimulator),
        Row(id: "brew.cleanup", candidates: brew, arguments: ["cleanup", "--prune=30"],
            seconds: 300, preflight: .processNotRunning("brew")),
        Row(id: "pnpm.storePrune", candidates: pnpm, arguments: ["store", "prune"],
            seconds: 300, preflight: .processNotRunning("pnpm")),
        Row(id: "go.cleanCache", candidates: go, arguments: ["clean", "-cache"], seconds: 300, preflight: .none),
        Row(id: "go.cleanModcache", candidates: go, arguments: ["clean", "-modcache"], seconds: 300, preflight: .none),
        Row(id: "docker.imagePrune", candidates: docker, arguments: ["image", "prune", "-f"],
            seconds: 300, preflight: .dockerReachable),
        Row(id: "docker.builderPrune", candidates: docker,
            arguments: ["builder", "prune", "-f", "--filter", "until=168h"], seconds: 300, preflight: .dockerReachable),
    ]

    @Test func allowListMatchesTheBriefExactly() {
        let all = OwnerCommands.all
        #expect(all.count == Self.expected.count)
        for row in Self.expected {
            let definition = all[OwnerCommandID(rawValue: row.id)]
            #expect(definition != nil, "missing \(row.id)")
            #expect(definition?.id.rawValue == row.id)
            #expect(definition?.candidates == row.candidates, "candidates of \(row.id)")
            #expect(definition?.arguments == row.arguments, "argv of \(row.id)")
            #expect(definition?.timeout == .seconds(row.seconds), "timeout of \(row.id)")
            #expect(definition?.preflight == row.preflight, "preflight of \(row.id)")
        }
    }

    @Test func everyKeyMatchesItsDefinitionAndEveryPathIsAbsolute() {
        for (key, definition) in OwnerCommands.all {
            #expect(key == definition.id)
            #expect(!definition.candidates.isEmpty)
            #expect(definition.candidates.allSatisfy { $0.hasPrefix("/") })
            #expect(!definition.arguments.isEmpty)
        }
    }

    @Test func perItemSimulatorCommandsAreNotInTheTable() {
        #expect(OwnerCommands.all[.simctlDeleteDevice] == nil)
        #expect(OwnerCommands.all[.simctlDeleteRuntime] == nil)
        #expect(OwnerCommands.all[.dockerInfo] == nil)
    }

    @Test func dockerInfoReusesTheGuardedCommandsExecutable() {
        let check = OwnerCommands.dockerInfo(candidates: ["/x/docker"])
        #expect(check.candidates == ["/x/docker"])
        #expect(check.arguments == ["info", "--format", "{{.ServerVersion}}"])
        #expect(check.timeout == .seconds(10))
    }

    @Test func anIDThatIsNotListedNeverRuns() async {
        let runner = OwnerCommandRunner()
        for text in ["rm.everything", "", "simctl.deleteDevice", "docker.info", "brew.cleanup "] {
            let result = await runner.run(OwnerCommandID(rawValue: text))
            #expect(result.skipped == "not an allowed command", "\(text)")
            #expect(result.executable == nil)
            #expect(result.exitCode == nil)
            #expect(!result.succeeded)
        }
    }

    @Test func resultSurvivesAJSONRoundTrip() throws {
        let result = OwnerCommandResult(
            id: .brewCleanup, executable: "/opt/homebrew/bin/brew", exitCode: 0, timedOut: false,
            skipped: nil, outputTail: "done\n", duration: .milliseconds(1500)
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(OwnerCommandResult.self, from: data)
        #expect(decoded.id == .brewCleanup)
        #expect(decoded.executable == result.executable)
        #expect(decoded.exitCode == 0)
        #expect(decoded.outputTail == "done\n")
        #expect(decoded.duration == .milliseconds(1500))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"brew.cleanup\""))
    }
}
