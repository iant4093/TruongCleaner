import Foundation
import Testing
@testable import CleanerCore

/// Shape of the catalog: what exists and that every row is well formed.
struct CatalogTests {
    private struct Expected: Sendable {
        let id: String
        let category: CleanerCore.Category
        let tier: Tier
    }

    /// `docs/RULE_CATALOG.md` §4.1 to §4.5, in catalog order.
    private static let expected: [Expected] = [
        Expected(id: "user.caches", category: .caches, tier: .safe),
        Expected(id: "user.containerCaches", category: .caches, tier: .safe),
        Expected(id: "user.groupContainerCaches", category: .caches, tier: .safe),
        Expected(id: "user.savedState", category: .caches, tier: .safe),
        Expected(id: "user.darwinCache", category: .caches, tier: .review),
        Expected(id: "user.darwinTemp", category: .caches, tier: .review),
        Expected(id: "user.gpuCaches", category: .caches, tier: .safe),
        Expected(id: "user.quickLook", category: .caches, tier: .safe),
        Expected(id: "system.libraryCaches", category: .caches, tier: .info),
        Expected(id: "logs.user", category: .logs, tier: .safe),
        Expected(id: "logs.userCrash", category: .logs, tier: .safe),
        Expected(id: "logs.crashReporter", category: .logs, tier: .safe),
        Expected(id: "logs.coreSimulator", category: .logs, tier: .safe),
        Expected(id: "logs.system", category: .logs, tier: .info),
        Expected(id: "logs.unified", category: .logs, tier: .info),
        Expected(id: "trash.user", category: .trash, tier: .review),
        Expected(id: "trash.ours", category: .trash, tier: .safe),
        Expected(id: "trash.volumes", category: .trash, tier: .review),
        Expected(id: "browser.safari", category: .browsers, tier: .safe),
        Expected(id: "browser.chromium", category: .browsers, tier: .safe),
        Expected(id: "browser.chromiumModels", category: .browsers, tier: .review),
        Expected(id: "browser.firefox", category: .browsers, tier: .safe),
        Expected(id: "apps.electronCaches", category: .apps, tier: .safe),
        Expected(id: "apps.spotifyMedia", category: .apps, tier: .safe),
        Expected(id: "apps.adobeMediaCache", category: .apps, tier: .review),
        Expected(id: "apps.steam", category: .apps, tier: .safe),
        Expected(id: "apps.cloudClientCaches", category: .apps, tier: .safe),
    ]

    @Test func catalogHasExactlyTheCatalogIDsInOrder() {
        #expect(Catalog.all.map(\.id) == Self.expected.map(\.id))
    }

    @Test func tierAndCategoryMatchTheCatalog() {
        for (rule, expected) in zip(Catalog.all, Self.expected) {
            #expect(rule.category == expected.category, "\(rule.id) category")
            #expect(rule.tier == expected.tier, "\(rule.id) tier")
        }
    }

    @Test func everyRuleIsWellFormed() throws {
        let idShape = try Regex("^[a-z]+\\.[A-Za-z]+$")
        let policy = TestEnv.policy()
        var seen: Set<String> = []

        for rule in Catalog.all {
            #expect(seen.insert(rule.id).inserted, "duplicate ID \(rule.id)")
            #expect(rule.id.wholeMatch(of: idShape) != nil, "\(rule.id) does not match the ID format")
            #expect(!String(localized: rule.title).isEmpty, "\(rule.id) has no title")
            #expect(!String(localized: rule.explain).isEmpty, "\(rule.id) has no explanation")
            #expect(rule.depth >= 1, "\(rule.id) depth")
            #expect(!rule.roots.isEmpty, "\(rule.id) has no roots")

            if rule.tier == .info {
                #expect(rule.action == .none, "\(rule.id) is Info and must have no action")
                #expect(rule.match == .measureOnly, "\(rule.id) is Info and must only measure")
            } else {
                #expect(rule.action != .none, "\(rule.id) is not Info and needs an action")
            }
            if rule.access == .root {
                #expect(rule.tier == .info, "\(rule.id): root access is for Info rules only in v1")
            }

            for spec in rule.roots {
                guard let expanded = RootExpansion.expand(spec, in: TestEnv.environment()) else {
                    Issue.record("\(rule.id): root \(spec.components) does not expand")
                    continue
                }
                if expanded.isConcrete {
                    #expect(
                        !policy.isRoot(expanded.base, roots: []),
                        "\(rule.id): root \(expanded.base.path()) is a folder we never delete from the top"
                    )
                } else {
                    #expect(!expanded.pattern.isEmpty)
                }
            }
        }
    }

    @Test func inertPlaceholdersAreExactlyTheKnownOnes() {
        let inert = Catalog.all.filter { $0.tier != .info && $0.match == .measureOnly }
        #expect(Set(inert.map(\.id)) == CatalogFixture.inertRuleIDs)
    }

    @Test func nonInfoRulesNeverRootInTheSystemLibrary() {
        // `everyRuleIsWellFormed` rejects `/` and `/Library` as roots. A deleting rule also must
        // not take the shared system Caches or Logs folder; those are Info rows.
        let forbidden: [[String]] = [["Library"], ["Library", "Caches"], ["Library", "Logs"]]
        for rule in Catalog.all where rule.tier != .info {
            for spec in rule.roots where spec.base == .absolute {
                #expect(!forbidden.contains(spec.components), "\(rule.id) must not clean a system folder")
            }
        }
    }
}
