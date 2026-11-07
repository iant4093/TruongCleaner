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
        #expect(rule.guards.owners == [.childNameAsBundleID])
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

    @Test func chromiumRulesNameEveryBrowserAsOwner() throws {
        let rule = try CatalogFixture.rule("browser.chromium")
        #expect(rule.guards.owners.count == BrowserRules.chromiumBrowsers.count)
        for browser in BrowserRules.chromiumBrowsers {
            #expect(rule.guards.owners.contains(.bundleID(browser.bundleID)))
        }
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
        ]
        for (id, count) in days {
            #expect(try CatalogFixture.rule(id).guards.minAge == .seconds(count * 86_400), "\(id)")
        }
        let withoutAge = Catalog.all.filter { days[$0.id] == nil }
        #expect(withoutAge.allSatisfy { $0.guards.minAge == nil })
    }

    @Test func reviewRulesAreTheOnesTheCatalogMarksReview() {
        let review = Set(Catalog.all.filter { $0.tier == .review }.map(\.id))
        #expect(review == [
            "user.darwinCache", "user.darwinTemp", "trash.user", "trash.volumes",
            "browser.chromiumModels", "apps.adobeMediaCache",
        ])
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
