import Foundation
import Testing
@testable import CleanerCore

/// Rule-specific checks from brief 3.2.
struct CatalogSpecificTests {
    private func root(_ rule: Rule, _ index: Int = 0) throws -> URL {
        try #require(try CatalogFixture.concreteRoots(rule)[safe: index])
    }

    @Test func crashReportsNeverOfferTheDiagnosticReportsFolder() throws {
        let rule = try CatalogFixture.rule("logs.userCrash")
        let reports = try root(rule)
        #expect(reports.lastPathComponent == "DiagnosticReports")
        let candidates = [
            CatalogFixture.candidate(reports, depth: 0),
            CatalogFixture.candidate(reports, depth: 1),
            // The parent is outside the root.
            CatalogFixture.candidate(reports.deletingLastPathComponent(), depth: 1),
            // A subfolder is not a file.
            CatalogFixture.candidate(reports.appending(path: "Retired", directoryHint: .isDirectory)),
            CatalogFixture.candidate(
                reports.appending(path: "app.ips", directoryHint: .notDirectory), isDirectory: false
            ),
        ]
        let outcomes = CatalogFixture.evaluate(rule, root: reports, candidates)
        #expect(CatalogFixture.summary(outcomes) == ["DiagnosticReports:isRoot", "DiagnosticReports:isRoot", "Logs:outsideRoots", "app.ips"])
    }

    @Test func userLogsKeepFoldersAndOurOwnLogFolder() throws {
        let rule = try CatalogFixture.rule("logs.user")
        let logs = try root(rule)
        let candidates = [
            CatalogFixture.candidate(logs.appending(path: "Homebrew", directoryHint: .isDirectory)),
            CatalogFixture.candidate(
                logs.appending(path: "app.log", directoryHint: .notDirectory), isDirectory: false
            ),
            CatalogFixture.candidate(
                logs.appending(path: "Homebrew/build.log", directoryHint: .notDirectory), depth: 2, isDirectory: false
            ),
            CatalogFixture.candidate(
                logs.appending(path: "Homebrew/deep/build.log", directoryHint: .notDirectory), depth: 3, isDirectory: false
            ),
            CatalogFixture.candidate(
                logs.appending(path: "TruongCleaner/run.log", directoryHint: .notDirectory), depth: 2, isDirectory: false
            ),
            CatalogFixture.candidate(
                logs.appending(path: "app.log", directoryHint: .notDirectory), isDirectory: false, modified: TestEnv.days(2)
            ),
        ]
        let outcomes = CatalogFixture.evaluate(rule, root: logs, candidates)
        // The folder (no match), the depth-3 file (too deep) are left out entirely.
        #expect(CatalogFixture.summary(outcomes) == ["app.log", "build.log", "run.log:excludedName", "app.log:tooNew"])
    }

    @Test func userCachesLeavesBrowserFoldersToTheBrowserRules() throws {
        let rule = try CatalogFixture.rule("user.caches")
        let caches = try root(rule)
        for name in ["Google", "Firefox"] {
            #expect(rule.guards.excludeNames.contains(name))
        }
        let names = ["Google", "Firefox", "com.example.App", "BraveSoftware"]
        let candidates = names.map { CatalogFixture.candidate(caches.appending(path: $0, directoryHint: .isDirectory)) }
        let outcomes = CatalogFixture.evaluate(rule, root: caches, candidates)
        #expect(CatalogFixture.summary(outcomes) == ["Google:excludedName", "Firefox:excludedName", "com.example.App", "BraveSoftware:excludedName"])
        #expect(rule.guards.owners == [.childNameAsBundleID(stripSuffix: nil)])
    }

    @Test func firefoxNeverOffersAProfileFolder() throws {
        let rule = try CatalogFixture.rule("browser.firefox")
        let roots = try CatalogFixture.concreteRoots(rule)
        #expect(roots.count == 2)
        let profile = TestEnv.url("~/Library/Application Support/Firefox/Profiles/x")
        let profiles = profile.deletingLastPathComponent()
        let firefoxSupport = profiles.deletingLastPathComponent()
        let candidates = [
            CatalogFixture.candidate(profile),
            CatalogFixture.candidate(profiles),
            CatalogFixture.candidate(firefoxSupport),
        ]
        for root in roots {
            let outcomes = CatalogFixture.evaluate(rule, root: root, candidates)
            #expect(CatalogFixture.findings(outcomes).isEmpty, "\(root.path())")
        }
        // Only the cache2 folder's children are roots' contents.
        let cache2 = try #require(roots.last)
        #expect(cache2.lastPathComponent == "cache2")
        let entry = CatalogFixture.candidate(cache2.appending(path: "entries", directoryHint: .isDirectory))
        #expect(CatalogFixture.findings(CatalogFixture.evaluate(rule, root: cache2, [entry])).count == 1)
    }

    @Test func safariRootsNeedFullDiskAccess() throws {
        let rule = try CatalogFixture.rule("browser.safari")
        #expect(rule.access == .fda)
        #expect(rule.roots.count == 2)
        #expect(rule.guards.owners == [.bundleID("com.apple.Safari")])
    }

    @Test func safariCacheDoesNotReachSafariUserData() throws {
        let rule = try CatalogFixture.rule("browser.safari")
        let userData = TestEnv.url("~/Library/Safari/History.db")
        for root in try CatalogFixture.concreteRoots(rule) {
            let outcomes = CatalogFixture.evaluate(rule, root: root, [CatalogFixture.candidate(userData)])
            #expect(CatalogFixture.skipReasons(outcomes) == [.outsideRoots])
        }
    }

    @Test func chromiumRootsCarryOnlyTheirOwnBrowserAsOwner() throws {
        let rule = try CatalogFixture.rule("browser.chromium")
        #expect(rule.guards.owners.isEmpty, "browser owners belong to the roots, not the rule")
        var seen: Set<String> = []
        for browser in BrowserRules.chromiumBrowsers {
            let own = rule.roots.filter { $0.owners == [.bundleID(browser.bundleID)] }
            // One cache root, six profile cache folders, four browser-level folders.
            #expect(own.count == 1 + BrowserRules.profileCacheFolders.count + BrowserRules.browserLevelCacheFolders.count)
            seen.insert(browser.bundleID)
        }
        #expect(seen.count == BrowserRules.chromiumBrowsers.count)
        #expect(rule.roots.allSatisfy { $0.owners.count == 1 })
    }

    @Test func chromiumOwnersFollowTheRootAFindingLiesUnder() throws {
        let rule = try CatalogFixture.rule("browser.chromium")
        let chrome = TestEnv.url("~/Library/Application Support/Google/Chrome/Default/Cache")
        let brave = TestEnv.url("~/Library/Caches/BraveSoftware/Brave-Browser")
        let chromeShader = TestEnv.url("~/Library/Application Support/Google/Chrome/ShaderCache")
        #expect(rule.rootOwners(for: chrome) == [.bundleID("com.google.Chrome")])
        #expect(rule.rootOwners(for: chromeShader) == [.bundleID("com.google.Chrome")])
        #expect(rule.rootOwners(for: brave) == [.bundleID("com.brave.Browser")])
        #expect(rule.rootOwners(for: TestEnv.url("~/Library/Caches/Unrelated")).isEmpty)
    }

    @Test func chromiumRootsNeverIncludeProfileData() throws {
        let rule = try CatalogFixture.rule("browser.chromium")
        let data: Set<String> = [
            "Cookies", "History", "Login Data", "Preferences", "Local Storage", "Extensions",
            "Bookmarks", "IndexedDB", "Sessions", "Web Data",
        ]
        for spec in rule.roots {
            #expect(data.isDisjoint(with: spec.components), "\(spec.components)")
        }
    }

    @Test func electronRootsAreOnlyTheListedCacheFolders() throws {
        let rule = try CatalogFixture.rule("apps.electronCaches")
        let allowed = Set(AppRules.electronCacheFolders.map { $0.joined(separator: "/") })
        #expect(rule.roots.count == AppRules.electronApps.count * AppRules.electronCacheFolders.count)
        for spec in rule.roots {
            let prefix = ["Library", "Application Support"]
            #expect(Array(spec.components.prefix(2)) == prefix)
            let matched = allowed.contains { spec.components.joined(separator: "/").hasSuffix("/" + $0) }
            #expect(matched, "\(spec.components)")
        }
    }

    @Test func electronRootsCarryOnlyTheirOwnAppsAsOwners() throws {
        let rule = try CatalogFixture.rule("apps.electronCaches")
        #expect(rule.guards.owners.isEmpty, "app owners belong to the roots, not the rule")
        for app in AppRules.electronApps {
            let expected = app.bundleIDs.map { OwnerSpec.bundleID($0) }
            let own = rule.roots.filter { Array($0.components.dropFirst(2).prefix(app.support.count)) == app.support }
            #expect(own.count == AppRules.electronCacheFolders.count, "\(app.support)")
            #expect(own.allSatisfy { $0.owners == expected }, "\(app.support)")
        }
        let slack = TestEnv.url("~/Library/Application Support/Slack/Cache")
        let teams = TestEnv.url("~/Library/Application Support/Microsoft/Teams/GPUCache")
        #expect(rule.rootOwners(for: slack) == [.bundleID("com.tinyspeck.slackmacgap")])
        #expect(rule.rootOwners(for: teams) == [.bundleID("com.microsoft.teams"), .bundleID("com.microsoft.teams2")])
    }

    @Test func darwinCacheRulesUseTheDarwinFolders() throws {
        #expect(try CatalogFixture.rule("user.darwinCache").roots == [RootSpec(base: .darwinUserCache, components: [])])
        #expect(try CatalogFixture.rule("user.darwinTemp").roots == [RootSpec(base: .darwinUserTemp, components: [])])
        let gpu = try CatalogFixture.rule("user.gpuCaches")
        #expect(gpu.roots.allSatisfy { $0.base == .darwinUserCache && $0.components.first == "*" })
        #expect(gpu.roots.map { $0.components.last } == ["com.apple.metal", "com.apple.metalfe", "com.apple.gpuarchiver"])
    }

    @Test func minAgesMatchTheCatalog() throws {
        let days: [String: Int64] = [
            "user.darwinCache": 7, "user.darwinTemp": 3, "user.gpuCaches": 1,
            "logs.user": 7, "logs.userCrash": 7, "logs.crashReporter": 30, "logs.coreSimulator": 7,
            "dev.projectArtifacts": 30, "mail.downloads": 30,
            "installers.macOS": 14, "installers.downloads": 7, "installers.partial": 1,
        ]
        for (id, count) in days {
            #expect(try CatalogFixture.rule(id).guards.minAge == .seconds(count * 86_400), "\(id)")
        }
        let withoutAge = Catalog.all.filter { days[$0.id] == nil }
        #expect(withoutAge.allSatisfy { $0.guards.minAge == nil })
    }

    @Test func reviewRulesAreTheOnesTheCatalogMarksReview() {
        let review = Set(Catalog.all.filter { $0.tier == .review }.map(\.id))
        // `user.groupContainerCaches` is Review here, Safe in the catalog: no owner check is possible.
        #expect(review == [
            "user.darwinCache", "user.darwinTemp", "user.groupContainerCaches", "trash.user", "trash.volumes",
            "browser.chromiumModels", "apps.adobeMediaCache",
            "dev.xcodeArchives", "dev.simDevices", "dev.simRuntimes", "dev.goModules", "dev.gradle", "dev.maven",
            "dev.projectArtifacts", "ios.backups", "installers.macOS", "installers.downloads",
            // Review since 9.1: a saved edit of an attachment may be the only copy.
            "mail.downloads",
        ])
    }

    // MARK: Root segments

    private static let appleNames = [
        "com.apple.Notes", "COM.APPLE.mail", "group.com.apple.notes", "systemgroup.com.apple.configurationprofiles",
        "5A4RE8SF68.com.apple.Safari", "com.apple.",
    ]
    private static let otherNames = [
        "com.example.App", "net.apple.Tool", "group.com.example.app", "ABCDE12345.com.example.group",
        "applecom.apple", "com.applesauce.App",
    ]

    @Test(arguments: ["user.containerCaches", "user.groupContainerCaches"])
    func appleFoldersAreLeftOutOfTheWildcardRoots(id: String) throws {
        let rule = try CatalogFixture.rule(id)
        #expect(rule.guards.excludeRootSegments == ["com.apple.*", "group.com.apple.*", "*.com.apple.*", "systemgroup.*"])
        let spec = try #require(rule.roots.first)
        // Build the concrete root for one container name by replacing the `*` component.
        func root(_ name: String) -> URL {
            let parts = spec.components.map { $0 == "*" ? name : $0 }
            return parts.reduce(TestEnv.home) { $0.appending(path: $1, directoryHint: .isDirectory) }
        }
        for name in Self.appleNames {
            #expect(rule.excludesRoot(root(name)), "\(id) should leave out \(name)")
        }
        for name in Self.otherNames {
            #expect(!rule.excludesRoot(root(name)), "\(id) should keep \(name)")
        }
    }

    @Test func excludedRootOffersNothingAtTheMatcherLevel() throws {
        let rule = try CatalogFixture.rule("user.containerCaches")
        let apple = TestEnv.url("~/Library/Containers/com.apple.Notes/Data/Library/Caches")
        let other = TestEnv.url("~/Library/Containers/com.example.App/Data/Library/Caches")
        let appleItem = CatalogFixture.candidate(apple.appending(path: "blob", directoryHint: .isDirectory))
        let otherItem = CatalogFixture.candidate(other.appending(path: "blob", directoryHint: .isDirectory))
        let left = CatalogFixture.evaluate(rule, root: apple, [appleItem])
        #expect(CatalogFixture.findings(left).isEmpty)
        #expect(CatalogFixture.skipReasons(left) == [.outsideRoots])
        #expect(CatalogFixture.findings(CatalogFixture.evaluate(rule, root: other, [otherItem])).map(\.url) == [otherItem.url])
    }

    @Test func wildcardSegmentsOfAResolvedRootAreOnlyTheStarComponents() throws {
        // Only the `*` folder is matched against the patterns, not `Data`, `Library` or `Caches`.
        let rule = try CatalogFixture.rule("user.containerCaches")
        let tricky = TestEnv.url("~/Library/Containers/com.example.App/Data/Library/Caches")
        #expect(!rule.excludesRoot(tricky))
        let spec = try #require(rule.roots.first)
        #expect(spec.segment(at: 2, inConcreteRoot: tricky) == "com.example.App")
        #expect(spec.segment(at: 0, inConcreteRoot: tricky) == "Library")
        #expect(spec.segment(at: 6, inConcreteRoot: tricky) == nil)
        #expect(spec.segment(at: 2, inConcreteRoot: TestEnv.url("~/Library/Elsewhere/com.example.App")) == nil)
    }

    @Test func containerCachesAreOwnedByTheContainersApp() throws {
        let rule = try CatalogFixture.rule("user.containerCaches")
        #expect(rule.guards.owners == [.rootSegmentAsBundleID(index: 2)])
        #expect(rule.tier == .safe)
        let group = try CatalogFixture.rule("user.groupContainerCaches")
        #expect(group.guards.owners.isEmpty)
        #expect(group.tier == .review)
        #expect(group.match == .children && rule.match == .children)
    }

    @Test func savedStateStripsItsSuffixBeforeReadingABundleID() throws {
        let rule = try CatalogFixture.rule("user.savedState")
        #expect(rule.guards.owners == [.childNameAsBundleID(stripSuffix: ".savedState")])
        #expect(OwnerResolution.bundleID(fromName: "com.example.App.savedState", stripSuffix: ".savedState") == "com.example.App")
        #expect(OwnerResolution.bundleID(fromName: "com.example.App.SAVEDSTATE", stripSuffix: ".savedState") == "com.example.App")
        // Without the suffix the name is read as it is.
        #expect(OwnerResolution.bundleID(fromName: "com.example.App", stripSuffix: ".savedState") == "com.example.App")
        // Stripping must not turn a short name into a bundle ID, or leave an empty part.
        #expect(OwnerResolution.bundleID(fromName: "com.savedState", stripSuffix: ".savedState") == nil)
        #expect(OwnerResolution.bundleID(fromName: "a.b.savedState", stripSuffix: ".savedState") == nil)
        #expect(OwnerResolution.bundleID(fromName: "com.example.App.savedState", stripSuffix: nil) == "com.example.App.savedState")
        #expect(OwnerResolution.bundleID(fromName: "a..b", stripSuffix: nil) == nil)
    }

    @Test func trashRulesDeletePermanently() throws {
        #expect(try CatalogFixture.rule("trash.user").action == .deletePermanently)
        #expect(try CatalogFixture.rule("trash.volumes").action == .deletePermanently)
        #expect(try CatalogFixture.rule("trash.ours").action == .trash)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
