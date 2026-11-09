import Foundation
import Testing

@testable import CleanerCore

/// The synthetic rule `apps.uninstall` (`docs/UNINSTALLER.md` §4).
struct UninstallRuleTests {
    private typealias Fixtures = UninstallFixtures

    private func setup(
        _ app: AppFacts = Fixtures.app(), running: Bool? = false
    ) throws -> UninstallRule.Setup {
        try UninstallRule.make(for: app, isRunning: running, context: Fixtures.context()).get()
    }

    @Test func ruleIsReviewTrashWithTheAppAsItsOwner() throws {
        let rule = try setup().rule
        #expect(rule.id == "apps.uninstall")
        #expect(rule.tier == .review)
        #expect(rule.action == .trash)
        #expect(rule.match == .children)
        #expect(rule.guards.owners == [.bundleID("com.example.Foo")])
        #expect(rule.guards.minAge == nil)
    }

    @Test func rootsAreTheSearchedUserFoldersAndTheAppsParent() throws {
        let made = try setup(Fixtures.app(path: "/Applications/Vendor/Foo.app"))
        let paths = made.expandedRoots.map { $0.path(percentEncoded: false) }
        let library = "/Users/test/Library/"
        #expect(paths.count == 14)
        for place in LeftoverPlace.all where place.scope == .user {
            let expected = library + place.folder.components.joined(separator: "/")
            #expect(paths.contains { $0.hasPrefix(expected) && $0.dropFirst(expected.count).allSatisfy { $0 == "/" } }, "\(expected)")
        }
        #expect(paths.last == "/Applications/Vendor/")
        #expect(made.rule.roots.count == 14)
    }

    @Test func libraryFoldersOfAllUsersAreNeverRoots() throws {
        let paths = try setup().expandedRoots.map { $0.path(percentEncoded: false) }
        #expect(!paths.contains { $0.hasPrefix("/Library") })
        #expect(!paths.contains("/Users/test/") && !paths.contains("/Users/test/Library/"))
        #expect(!paths.contains { $0.contains("Documents") || $0.contains("Desktop") || $0.contains("Downloads") })
    }

    @Test func onlyTheInstallerRuleAndTheUninstallRuleMayRemoveAWholeApp() throws {
        #expect(try setup().rule.allowsWholeBundle)
        #expect(Rule.wholeBundleRuleID == "installers.macOS")
        #expect(Rule.uninstallRuleID == "apps.uninstall")
        #expect(UninstallRule.id == Rule.uninstallRuleID)
        // The catalog still holds exactly one such rule; the uninstall rule is never in it.
        #expect(Catalog.all.filter(\.allowsWholeBundle).map(\.id) == ["installers.macOS"])
        #expect(!Catalog.all.contains { $0.id == UninstallRule.id })
    }

    @Test func wholeBundleIsStillDecidedByTheRuleIDAlone() {
        for id in ["apps.uninstall.other", "apps.uninstal", "Apps.Uninstall", "installers.other", "apps"] {
            let imposter = Rule(
                id: id, category: .apps, tier: .review, roots: [], match: .children, access: .user,
                action: .trash, title: "x", explain: "x")
            #expect(!imposter.allowsWholeBundle, "\(id)")
        }
    }

    @Test func refusedAppsGetNoRule() {
        let context = Fixtures.context()
        let cases: [(AppFacts, Bool?, UninstallRefusal)] = [
            (Fixtures.app("com.apple.Safari"), false, .apple),
            (Fixtures.app(), true, .running),
            (Fixtures.app(), nil, .runningUnknown),
            (Fixtures.app(nil), false, .noBundleID),
            (Fixtures.app("com.iant4093.TruongCleaner"), false, .thisApp),
            (Fixtures.app(path: "/Users/test/Downloads/Foo.app"), false, .outsideApplicationFolders),
        ]
        for (app, running, refusal) in cases {
            switch UninstallRule.make(for: app, isRunning: running, context: context) {
            case .failure(let reason): #expect(reason == refusal)
            case .success: Issue.record("A rule was made for \(app.bundleID ?? "no ID")")
            }
        }
    }

    @Test func theTitleNamesTheApp() throws {
        let rule = try setup(Fixtures.app(name: "Foo", displayName: "Foo Deluxe")).rule
        #expect(String(localized: rule.title) == "Uninstall Foo Deluxe")
    }
}
