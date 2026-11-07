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

    /// `docs/RULE_CATALOG.md` §4.1 to §4.10, in catalog order.
    private static let expected: [Expected] = [
        Expected(id: "user.caches", category: .caches, tier: .safe),
        Expected(id: "user.containerCaches", category: .caches, tier: .safe),
        Expected(id: "user.groupContainerCaches", category: .caches, tier: .review),
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
        Expected(id: "dev.xcodeDerivedData", category: .developer, tier: .safe),
        Expected(id: "dev.xcodeDeviceSupport", category: .developer, tier: .safe),
        Expected(id: "dev.xcodePreviews", category: .developer, tier: .safe),
        Expected(id: "dev.xcodeCaches", category: .developer, tier: .safe),
        Expected(id: "dev.xcodeArchives", category: .developer, tier: .review),
        Expected(id: "dev.xcodeDocCache", category: .developer, tier: .safe),
        Expected(id: "dev.simUnavailable", category: .developer, tier: .safe),
        Expected(id: "dev.simDevices", category: .developer, tier: .review),
        Expected(id: "dev.simRuntimes", category: .developer, tier: .review),
        Expected(id: "dev.simCaches", category: .developer, tier: .safe),
        Expected(id: "dev.xctestDevices", category: .developer, tier: .safe),
        Expected(id: "dev.swiftpm", category: .developer, tier: .safe),
        Expected(id: "dev.homebrew", category: .developer, tier: .safe),
        Expected(id: "dev.npm", category: .developer, tier: .safe),
        Expected(id: "dev.yarn", category: .developer, tier: .safe),
        Expected(id: "dev.pnpm", category: .developer, tier: .safe),
        Expected(id: "dev.bun", category: .developer, tier: .safe),
        Expected(id: "dev.pip", category: .developer, tier: .safe),
        Expected(id: "dev.uv", category: .developer, tier: .safe),
        Expected(id: "dev.cargo", category: .developer, tier: .safe),
        Expected(id: "dev.go", category: .developer, tier: .safe),
        Expected(id: "dev.goModules", category: .developer, tier: .review),
        Expected(id: "dev.gradle", category: .developer, tier: .review),
        Expected(id: "dev.maven", category: .developer, tier: .review),
        Expected(id: "dev.cocoapods", category: .developer, tier: .safe),
        Expected(id: "dev.androidCaches", category: .developer, tier: .safe),
        Expected(id: "dev.dockerDangling", category: .developer, tier: .safe),
        Expected(id: "dev.dockerImage", category: .developer, tier: .info),
        Expected(id: "dev.projectArtifacts", category: .developer, tier: .review),
        Expected(id: "mail.downloads", category: .mail, tier: .safe),
        Expected(id: "mail.caches", category: .mail, tier: .safe),
        Expected(id: "mail.store", category: .mail, tier: .info),
        Expected(id: "mail.messagesPreviews", category: .mail, tier: .safe),
        Expected(id: "mail.messagesAttachments", category: .mail, tier: .info),
        Expected(id: "ios.backups", category: .ios, tier: .review),
        Expected(id: "ios.firmware", category: .ios, tier: .safe),
        Expected(id: "installers.macOS", category: .installers, tier: .review),
        Expected(id: "installers.downloads", category: .installers, tier: .review),
        Expected(id: "installers.partial", category: .installers, tier: .safe),
        Expected(id: "system.snapshots", category: .system, tier: .info),
        Expected(id: "system.purgeable", category: .system, tier: .info),
        Expected(id: "system.spotlight", category: .system, tier: .info),
        Expected(id: "system.swap", category: .system, tier: .info),
        Expected(id: "system.aiAssets", category: .system, tier: .info),
        Expected(id: "system.rosetta", category: .system, tier: .info),
        Expected(id: "system.updates", category: .system, tier: .info),
        Expected(id: "system.unexplained", category: .system, tier: .info),
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

            let walksNothing = CatalogFixture.isOwnerCommand(rule) || isComputed(rule)
            if walksNothing {
                #expect(rule.roots.isEmpty, "\(rule.id) walks nothing, so it has no roots")
            } else {
                #expect(!rule.roots.isEmpty, "\(rule.id) has no roots")
            }

            if case .computed(let key) = rule.match {
                #expect(rule.tier == .info, "\(rule.id): only Info rules are computed")
                #expect(!key.isEmpty, "\(rule.id): empty computed key")
            }
            if case .ownerCommand(let spec) = rule.match {
                #expect(rule.tier != .info, "\(rule.id): an Info rule cannot run a command")
                #expect(rule.action == .ownerCommand(spec), "\(rule.id): match and action name different commands")
                #expect(spec.executable.path().hasPrefix("/"), "\(rule.id): executable must be absolute")
                #expect(!spec.id.isEmpty, "\(rule.id): command has no ID")
            }

            if rule.tier == .info {
                #expect(rule.action == .none, "\(rule.id) is Info and must have no action")
                #expect(
                    rule.match == .measureOnly || isComputed(rule),
                    "\(rule.id) is Info and must only measure or be computed"
                )
            } else {
                #expect(rule.action != .none, "\(rule.id) is not Info and needs an action")
                #expect(rule.sanctionedCommand == nil && rule.settingsURL == nil, "\(rule.id): only Info rows point to a fix")
            }
            if rule.access == .root {
                #expect(rule.tier == .info, "\(rule.id): root access is for Info rules only in v1")
            }

            for spec in rule.roots {
                let starts = RootExpansion.starts(of: spec, in: TestEnv.environment())
                #expect(!starts.isEmpty, "\(rule.id): root \(spec.components) has no starting folder")
                for start in starts {
                    guard let expanded = RootExpansion.expand(spec, from: start) else {
                        Issue.record("\(rule.id): root \(spec.components) does not expand")
                        continue
                    }
                    if expanded.isConcrete {
                        // A glob picks named items out of a well-known folder, so `/Applications` may be
                        // the root of `installers.macOS`. Any other rule would clean the folder's children.
                        let allowed = Self.wellKnownRootRules.contains(rule.id)
                        #expect(
                            allowed || !policy.isRoot(expanded.base, roots: []),
                            "\(rule.id): root \(expanded.base.path()) is a folder we never delete from the top"
                        )
                    } else {
                        #expect(!expanded.pattern.isEmpty)
                    }
                }
            }
        }
    }

    /// Rules whose root is a folder `PathPolicy.isRoot` knows. Each has a glob that names the items.
    private static let wellKnownRootRules: Set<String> = ["installers.macOS"]

    private func isComputed(_ rule: Rule) -> Bool {
        if case .computed = rule.match { true } else { false }
    }

    @Test func wellKnownRootsBelongToGlobRulesOnly() {
        for id in Self.wellKnownRootRules {
            let rule = Catalog.all.first { $0.id == id }
            if case .glob = rule?.match {} else { Issue.record("\(id) must match with a glob") }
        }
    }

    @Test func computedKeysAreUnique() {
        let keys = Catalog.all.compactMap { rule -> String? in
            if case .computed(let key) = rule.match { key } else { nil }
        }
        #expect(keys.count == 5)
        #expect(Set(keys).count == keys.count)
    }

    @Test func inertPlaceholdersAreExactlyTheKnownOnes() {
        let inert = Catalog.all.filter { $0.tier != .info && $0.match == .measureOnly }
        #expect(Set(inert.map(\.id)) == CatalogFixture.inertRuleIDs)
    }

    @Test func onlyTheTrashRulesDeletePermanently() {
        let permanent = Catalog.all.filter { $0.action == .deletePermanently }.map(\.id)
        #expect(permanent == ["trash.user", "trash.volumes"])
        // Permanent delete is never selected by default.
        #expect(Catalog.all.filter { $0.action == .deletePermanently }.allSatisfy { $0.tier == .review })
    }

    @Test func excludeRootSegmentsOnlyAppearOnRulesWithAWildcardRoot() {
        for rule in Catalog.all where !rule.guards.excludeRootSegments.isEmpty {
            #expect(
                rule.roots.allSatisfy { $0.components.contains { $0.contains("*") } },
                "\(rule.id): every root needs a `*` for the patterns to apply to")
            for pattern in rule.guards.excludeRootSegments {
                #expect(!pattern.isEmpty && !pattern.contains("/"), "\(rule.id): bad pattern \(pattern)")
            }
        }
    }

    @Test func ownerSpecsPointInsideTheirRoots() {
        for rule in Catalog.all {
            for case .rootSegmentAsBundleID(let index) in rule.guards.owners {
                for spec in rule.roots {
                    #expect(
                        spec.components.indices.contains(index) && spec.components[index].contains("*"),
                        "\(rule.id): index \(index) must be a `*` component of every root")
                }
            }
        }
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
