import CleanerCore
import Foundation
import Testing

@testable import CleanerActions

/// The catalog's owner-command rules and the runner's allow-list (`OwnerCommands.all`) must agree.
/// `CleanerCore` cannot import `CleanerActions`, so this is the one place both are visible.
struct CatalogOwnerCommandTests {
    /// The two commands the runner builds per item (`deleteSimulator(udid:)`, `deleteSimulatorRuntime(identifier:)`).
    /// They are deliberately not in `OwnerCommands.all`: their last argument is validated input.
    private static let perItemIDs: Set<String> = [
        OwnerCommandID.simctlDeleteDevice.rawValue,
        OwnerCommandID.simctlDeleteRuntime.rawValue,
    ]

    /// Every spec of every owner-command rule, follow-ups included.
    private static func specs() -> [(rule: String, spec: OwnerCommandSpec)] {
        Catalog.all.flatMap { rule -> [(rule: String, spec: OwnerCommandSpec)] in
            guard case .ownerCommand(let spec) = rule.match else { return [] }
            var all: [OwnerCommandSpec] = []
            var queue = [spec]
            while let next = queue.popLast() {
                all.append(next)
                queue.append(contentsOf: next.followUps)
            }
            return all.map { (rule: rule.id, spec: $0) }
        }
    }

    @Test func thereAreOwnerCommandRules() {
        // 8 rules; dev.dockerDangling carries two commands.
        #expect(Self.specs().count == 9)
    }

    @Test func everyCatalogCommandIDExistsInTheRunner() {
        let known = Set(OwnerCommands.all.keys.map(\.rawValue)).union(Self.perItemIDs)
        for (rule, spec) in Self.specs() {
            #expect(known.contains(spec.id), "\(rule): \(spec.id) is not a command the runner knows")
        }
    }

    @Test func theTwoPerItemCommandsAreNotInTheAllowListTable() {
        for id in Self.perItemIDs {
            #expect(OwnerCommands.all[OwnerCommandID(rawValue: id)] == nil, "\(id)")
        }
        let used = Set(Self.specs().map(\.spec.id))
        #expect(Self.perItemIDs.isSubset(of: used))
    }

    @Test func tableCommandsMatchTheirDefinitionExactly() throws {
        for (rule, spec) in Self.specs() where !Self.perItemIDs.contains(spec.id) {
            let definition = try #require(OwnerCommands.all[OwnerCommandID(rawValue: spec.id)], "\(rule)")
            #expect(spec.arguments == definition.arguments, "\(rule) argv")
            #expect(spec.timeout == definition.timeout, "\(rule) timeout")
            #expect(definition.candidates.contains(spec.executable.path(percentEncoded: false)), "\(rule) executable")
        }
    }

    @Test func perItemCommandsAreTheFixedPartOfTheRunnersArgv() throws {
        let device = try #require(Self.specs().first { $0.spec.id == "simctl.deleteDevice" }).spec
        let runtime = try #require(Self.specs().first { $0.spec.id == "simctl.deleteRuntime" }).spec
        // OwnerCommandRunner appends the validated UDID or runtime identifier.
        #expect(device.executable.path(percentEncoded: false) == "/usr/bin/xcrun")
        #expect(device.arguments == ["simctl", "delete"])
        #expect(device.timeout == .seconds(120))
        #expect(runtime.executable.path(percentEncoded: false) == "/usr/bin/xcrun")
        #expect(runtime.arguments == ["simctl", "runtime", "delete"])
        #expect(runtime.timeout == .seconds(300))
    }

    @Test func everyAllowListedCommandIsUsedByExactlyOneRule() {
        let used = Self.specs().map(\.spec.id).filter { !Self.perItemIDs.contains($0) }
        #expect(Set(used) == Set(OwnerCommands.all.keys.map(\.rawValue)))
        #expect(used.count == Set(used).count)
    }

    @Test func noRuleOtherThanOwnerCommandRulesHasACommandAction() {
        for rule in Catalog.all {
            if case .ownerCommand = rule.action {
                if case .ownerCommand = rule.match {} else { Issue.record("\(rule.id): action without a matching command") }
            }
        }
    }

    @Test func onlyTheMacOSInstallerRuleAllowsWholeBundles() {
        #expect(Catalog.all.filter(\.allowsWholeBundle).map(\.id) == ["installers.macOS"])
    }
}
