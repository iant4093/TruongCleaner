import Foundation
import Testing
@testable import CleanerCore

/// Rule-specific checks for `docs/RULE_CATALOG.md` §4.6 to §4.10 (brief 4.2).
struct CatalogPart2Tests {
    private func root(_ rule: Rule, _ index: Int = 0) throws -> URL {
        let roots = try CatalogFixture.concreteRoots(rule)
        return try #require(roots.indices.contains(index) ? roots[index] : nil)
    }

    private func folder(_ parent: URL, _ components: String...) -> URL {
        components.reduce(parent) { $0.appending(path: $1, directoryHint: .isDirectory) }
    }

    // MARK: - Developer

    @Test func xcodeArchivesAreReviewAndOnlyDateFolderArchives() throws {
        let rule = try CatalogFixture.rule("dev.xcodeArchives")
        #expect(rule.tier == .review)
        let archives = try root(rule)
        let found = CatalogFixture.candidate(folder(archives, "2025-01-01", "App.xcarchive"), depth: 2)
        let loose = CatalogFixture.candidate(folder(archives, "App.xcarchive"), depth: 1)
        let notAnArchive = CatalogFixture.candidate(folder(archives, "2025-01-01", "App.txt"), depth: 2)
        let tooDeep = CatalogFixture.candidate(folder(archives, "2025", "x", "App.xcarchive"), depth: 3)
        let outcomes = CatalogFixture.evaluate(rule, root: archives, [found, loose, notAnArchive, tooDeep])
        #expect(CatalogFixture.findings(outcomes).map(\.url) == [found.url])
        #expect(outcomes.count == 1)
    }

    @Test func deviceSupportHasOneRootPerPlatformAndKeepsTwoNewest() throws {
        let rule = try CatalogFixture.rule("dev.xcodeDeviceSupport")
        let names = try CatalogFixture.concreteRoots(rule).map(\.lastPathComponent)
        #expect(names == [
            "iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport",
            "visionOS DeviceSupport", "macOS DeviceSupport",
        ])
        #expect(rule.guards.keepNewest == 2)
    }

    @Test func xcodeRulesWaitForXcodeAndXcodebuild() throws {
        for id in ["dev.xcodeDerivedData", "dev.xcodePreviews", "dev.xcodeCaches"] {
            let rule = try CatalogFixture.rule(id)
            #expect(rule.guards.owners == [.bundleID("com.apple.dt.Xcode"), .processName("xcodebuild")], "\(id)")
        }
    }

    @Test func ownerCommandRulesUseTheTiersAndRootsOfTheCatalog() throws {
        let expected: [String: Tier] = [
            "dev.simUnavailable": .safe, "dev.simDevices": .review, "dev.simRuntimes": .review,
            "dev.homebrew": .safe, "dev.pnpm": .safe, "dev.go": .safe, "dev.goModules": .review,
            "dev.dockerDangling": .safe,
        ]
        #expect(Set(CatalogFixture.ownerCommandRuleIDs) == Set(expected.keys))
        for (id, tier) in expected {
            let rule = try CatalogFixture.rule(id)
            #expect(rule.tier == tier, "\(id)")
            #expect(rule.roots.isEmpty, "\(id)")
        }
    }

    @Test func dockerDanglingRunsImagePruneThenBuilderPrune() throws {
        let rule = try CatalogFixture.rule("dev.dockerDangling")
        guard case .ownerCommand(let first) = rule.action else {
            Issue.record("dev.dockerDangling needs an owner command")
            return
        }
        #expect(first.id == "docker.imagePrune")
        #expect(first.arguments == ["image", "prune", "-f"])
        let second = try #require(first.followUps.first)
        #expect(first.followUps.count == 1)
        #expect(second.id == "docker.builderPrune")
        #expect(second.arguments == ["builder", "prune", "-f", "--filter", "until=168h"])
        #expect(second.followUps.isEmpty)
        // Volumes are never pruned.
        #expect(!([first] + first.followUps).contains { $0.arguments.contains("volume") || $0.arguments.contains("-a") })
    }

    @Test func dockerImageIsInfoWithNoCommand() throws {
        let rule = try CatalogFixture.rule("dev.dockerImage")
        #expect(rule.tier == .info && rule.action == .none && rule.access == .fda)
        #expect(rule.sanctionedCommand == nil)
    }

    @Test func npmRootDoesNotReachNpx() throws {
        let rule = try CatalogFixture.rule("dev.npm")
        let cacache = try root(rule)
        #expect(cacache.lastPathComponent == "_cacache")
        let npx = CatalogFixture.candidate(cacache.deletingLastPathComponent().appending(path: "_npx", directoryHint: .isDirectory))
        #expect(CatalogFixture.skipReasons(CatalogFixture.evaluate(rule, root: cacache, [npx])) == [.outsideRoots])
    }

    @Test func cargoRootLeavesSourcesIndexAndGitAlone() throws {
        let rule = try CatalogFixture.rule("dev.cargo")
        let cache = try root(rule)
        #expect(cache.path().hasSuffix("/.cargo/registry/cache/"))
        for sibling in ["src", "index"] {
            let url = cache.deletingLastPathComponent().appending(path: sibling, directoryHint: .isDirectory)
            #expect(CatalogFixture.skipReasons(CatalogFixture.evaluate(rule, root: cache, [CatalogFixture.candidate(url)])) == [.outsideRoots])
        }
    }

    @Test func androidCachesHasAWildcardForStudioVersions() throws {
        let rule = try CatalogFixture.rule("dev.androidCaches")
        #expect(rule.roots.count == 3)
        #expect(rule.roots.last?.components == ["Library", "Caches", "Google", "AndroidStudio*"])
    }

    // MARK: - Project artifacts

    private func artifactEvaluate(
        _ candidates: [Candidate], listings: [URL: Set<String>] = [:]
    ) throws -> [MatchOutcome] {
        let rule = try CatalogFixture.rule("dev.projectArtifacts")
        return CatalogFixture.evaluate(rule, root: TestEnv.projectFolder, candidates, listings: listings)
    }

    private func artifact(_ components: String..., modified: Date? = TestEnv.days(60)) -> Candidate {
        artifact(at: components, modified: modified)
    }

    private func artifact(at components: [String], modified: Date? = TestEnv.days(60)) -> Candidate {
        let url = components.reduce(TestEnv.projectFolder) { $0.appending(path: $1, directoryHint: .isDirectory) }
        return CatalogFixture.candidate(url, depth: components.count, modified: modified)
    }

    @Test func projectArtifactsRootsAreTheChosenFolders() throws {
        let rule = try CatalogFixture.rule("dev.projectArtifacts")
        #expect(rule.tier == .review)
        #expect(rule.roots == [RootSpec(base: .userChosen, components: [])])
        #expect(try CatalogFixture.concreteRoots(rule) == [TestEnv.projectFolder])
        #expect(rule.guards.minAge == .days(30))
        #expect(rule.depth == 6)
    }

    @Test func nodeModulesUnderAProjectIsOfferedButNotOneAtTheFolderRoot() throws {
        let inProject = artifact("app", "node_modules")
        let atRoot = artifact("node_modules")
        let outcomes = try artifactEvaluate([inProject, atRoot])
        #expect(CatalogFixture.findings(outcomes).map(\.url) == [inProject.url])
        #expect(outcomes.count == 1)
    }

    @Test(arguments: [
        ["app", ".build"], ["app", "DerivedData"], ["app", ".venv"], ["app", "__pycache__"], ["app", "Pods"],
        ["app", ".gradle"], ["app", ".dart_tool"], ["a", "b", "c", "node_modules"], ["app", ".next", "cache"],
    ])
    func everyArtifactNameIsOffered(path: [String]) throws {
        let candidate = artifact(at: path)
        let outcomes = try artifactEvaluate([candidate])
        #expect(CatalogFixture.findings(outcomes).map(\.url) == [candidate.url], "\(path)")
    }

    @Test func otherNamesAndTheNextFolderItselfAreNotOffered() throws {
        let outcomes = try artifactEvaluate([
            artifact("app", "src"), artifact("app", ".next"), artifact("app", "cache"), artifact("app", "Build2"),
        ])
        #expect(outcomes.isEmpty)
    }

    @Test func artifactsDeeperThanSixLevelsAreNotMatched() throws {
        let fiveDeep = artifact("a", "b", "c", "d", "node_modules")
        #expect(CatalogFixture.findings(try artifactEvaluate([fiveDeep])).map(\.url) == [fiveDeep.url])
        let tooDeep = CatalogFixture.candidate(
            folder(TestEnv.projectFolder, "a", "b", "c", "d", "e", "f", "node_modules"), depth: 7)
        #expect(try artifactEvaluate([tooDeep]).isEmpty)
    }

    @Test func targetNeedsCargoTomlBesideIt() throws {
        let target = artifact("rust", "target")
        let beside = folder(TestEnv.projectFolder, "rust")
        let withManifest = try artifactEvaluate([target], listings: [beside: ["Cargo.toml", "src", "target"]])
        #expect(CatalogFixture.findings(withManifest).map(\.url) == [target.url])
        let withoutManifest = try artifactEvaluate([target], listings: [beside: ["src", "target", "pom.xml"]])
        #expect(CatalogFixture.skipReasons(withoutManifest) == [.missingSibling])
        // No listing at all means unknown, which means keep.
        #expect(CatalogFixture.skipReasons(try artifactEvaluate([target])) == [.missingSibling])
    }

    @Test(arguments: ["build.gradle", "build.gradle.kts", "CMakeLists.txt", "package.json", "Makefile"])
    func buildNeedsOneOfTheBuildFiles(file: String) throws {
        let build = artifact("proj", "build")
        let beside = folder(TestEnv.projectFolder, "proj")
        let outcomes = try artifactEvaluate([build], listings: [beside: [file, "build"]])
        #expect(CatalogFixture.findings(outcomes).map(\.url) == [build.url], "\(file)")
        let without = try artifactEvaluate([build], listings: [beside: ["README.md", "build"]])
        #expect(CatalogFixture.skipReasons(without) == [.missingSibling])
    }

    @Test func otherArtifactsNeedNoSibling() throws {
        let modules = artifact("app", "node_modules")
        #expect(CatalogFixture.findings(try artifactEvaluate([modules])).count == 1)
    }

    @Test func anArtifactHoldingAGitEntryIsKept() throws {
        let modules = artifact("app", "node_modules")
        let outcomes = try artifactEvaluate([modules], listings: [modules.url: [".git", "pkg"]])
        #expect(CatalogFixture.skipReasons(outcomes) == [.excludedName])
        #expect(CatalogFixture.findings(outcomes).isEmpty)
        // A `.git` file (worktrees, submodules) counts too, whatever its case.
        let upper = try artifactEvaluate([modules], listings: [modules.url: [".GIT"]])
        #expect(CatalogFixture.skipReasons(upper) == [.excludedName])
    }

    @Test func anArtifactAtTheLastScannedLevelCannotBeChecked() throws {
        // Its inside was not listed, so it might hold `.git`. Unknown means keep.
        let atLimit = artifact("a", "b", "c", "d", "e", "node_modules")
        #expect(atLimit.depth == 6)
        #expect(CatalogFixture.skipReasons(try artifactEvaluate([atLimit])) == [.excludedName])
    }

    @Test func anythingInsideAGitFolderIsKept() throws {
        let inGit = artifact("app", ".git", "modules", "build")
        let outcomes = try artifactEvaluate([inGit], listings: [folder(TestEnv.projectFolder, "app", ".git", "modules"): ["build", "package.json"]])
        #expect(CatalogFixture.skipReasons(outcomes) == [.excludedName])
    }

    @Test func aMatchInsideAnotherMatchIsPartOfTheOuterOne() throws {
        let outer = artifact("app", "node_modules")
        let inner = artifact("app", "node_modules", "pkg", "node_modules")
        let innerNext = artifact("app", "node_modules", "web", ".next", "cache")
        let outcomes = try artifactEvaluate([inner, outer, innerNext])
        #expect(CatalogFixture.findings(outcomes).map(\.url) == [outer.url])
        #expect(outcomes.count == 1)
    }

    @Test func aNewOuterArtifactDoesNotExposeTheOneInsideIt() throws {
        // `pkg/node_modules` belongs to `pkg`; removing it alone would break the package.
        let outer = artifact("app", "node_modules", modified: TestEnv.days(2))
        let inner = artifact("app", "node_modules", "pkg", "node_modules")
        let outcomes = try artifactEvaluate([outer, inner])
        #expect(CatalogFixture.summary(outcomes) == ["node_modules:tooNew"])
    }

    @Test func artifactsAreKeptUntilThirtyDaysOld() throws {
        let fresh = artifact("a", "node_modules", modified: TestEnv.days(29))
        let old = artifact("b", "node_modules", modified: TestEnv.days(31))
        let unknown = artifact("c", "node_modules", modified: nil)
        let outcomes = try artifactEvaluate([fresh, old, unknown])
        #expect(CatalogFixture.findings(outcomes).map(\.url) == [old.url])
        #expect(CatalogFixture.skipReasons(outcomes) == [.tooNew, .unknownAge])
    }

    @Test func artifactsInICloudAndCloudStorageFoldersAreNeverOffered() throws {
        let rule = try CatalogFixture.rule("dev.projectArtifacts")
        for place in ["Library/CloudStorage/Dropbox/app", "Library/Mobile Documents/com~apple~CloudDocs/app"] {
            let projects = TestEnv.url("~/" + place).deletingLastPathComponent()
            let item = CatalogFixture.candidate(TestEnv.url("~/" + place).appending(path: "node_modules", directoryHint: .isDirectory), depth: 2)
            let outcomes = CatalogFixture.evaluate(rule, root: projects, [item])
            #expect(CatalogFixture.skipReasons(outcomes) == [.protectedPath], "\(place)")
            // And such a folder cannot be chosen as a project folder at all.
            let env = TestEnv.environment(projectFolders: [projects])
            #expect(RootExpansion.starts(of: rule.roots[0], in: env).isEmpty, "\(place)")
        }
    }

    // MARK: - Mail

    @Test func mailRulesWaitForTheirApp() throws {
        for id in ["mail.downloads", "mail.caches"] {
            #expect(try CatalogFixture.rule(id).guards.owners == [.bundleID("com.apple.mail")], "\(id)")
        }
        #expect(try CatalogFixture.rule("mail.messagesPreviews").guards.owners == [.bundleID("com.apple.MobileSMS")])
    }

    @Test func mailRulesNeedFullDiskAccess() throws {
        for id in ["mail.downloads", "mail.caches", "mail.store", "mail.messagesPreviews", "mail.messagesAttachments"] {
            #expect(try CatalogFixture.rule(id).access == .fda, "\(id)")
        }
    }

    @Test func messagePreviewRootsAreExactlyThePreviewsAndStickers() throws {
        let rule = try CatalogFixture.rule("mail.messagesPreviews")
        let roots = try CatalogFixture.concreteRoots(rule)
        #expect(roots.map { $0.path(percentEncoded: false).replacing(TestEnv.homePath, with: "~") } == [
            "~/Library/Messages/Caches/Previews/", "~/Library/Messages/StickerCache/",
        ])
        // The protected list covers the rest of Messages, so attachments cannot be offered.
        let attachments = TestEnv.url("~/Library/Messages/Attachments/ab")
        for root in roots {
            #expect(CatalogFixture.skipReasons(CatalogFixture.evaluate(rule, root: root, [CatalogFixture.candidate(attachments)])) == [.outsideRoots])
        }
        // And the two folders themselves are not protected, so their children can be offered.
        for root in roots {
            let child = CatalogFixture.candidate(root.appending(path: "x", directoryHint: .isDirectory))
            #expect(CatalogFixture.findings(CatalogFixture.evaluate(rule, root: root, [child])).count == 1)
        }
    }

    // MARK: - iOS

    @Test func iosBackupsAreReviewChildrenThatNeedFullDiskAccess() throws {
        let rule = try CatalogFixture.rule("ios.backups")
        #expect(rule.tier == .review)
        #expect(rule.match == .children)
        #expect(rule.access == .fda)
    }

    @Test func firmwareChecksTheFourSoftwareUpdateFolders() throws {
        let rule = try CatalogFixture.rule("ios.firmware")
        let names = try CatalogFixture.concreteRoots(rule).map(\.lastPathComponent)
        #expect(names == [
            "iPhone Software Updates", "iPad Software Updates", "iPod Software Updates", "Apple TV Software Updates",
        ])
        #expect(rule.match == .files(extensions: ["ipsw"]))
    }

    // MARK: - Installers

    @Test func onlyTheMacOSInstallerRuleMayRemoveAWholeApp() {
        #expect(Catalog.all.filter(\.allowsWholeBundle).map(\.id) == ["installers.macOS"])
        #expect(Rule.wholeBundleRuleID == "installers.macOS")
    }

    @Test func macOSInstallerRuleOffersInstallAppsDirectlyInApplications() throws {
        let rule = try CatalogFixture.rule("installers.macOS")
        #expect(rule.tier == .review)
        #expect(rule.guards.minAge == .days(14))
        let apps = try root(rule)
        #expect(apps.path(percentEncoded: false) == "/Applications/")
        let installer = CatalogFixture.candidate(folder(apps, "Install macOS Sequoia.app"))
        let safari = CatalogFixture.candidate(folder(apps, "Safari.app"))
        let inside = CatalogFixture.candidate(folder(apps, "Install macOS Sequoia.app", "Contents"), depth: 2)
        let outcomes = CatalogFixture.evaluate(rule, root: apps, [installer, safari, inside])
        #expect(CatalogFixture.findings(outcomes).map(\.url) == [installer.url])
        #expect(outcomes.count == 1)
    }

    @Test func downloadedInstallersAreFilesOfTheListedKinds() throws {
        let rule = try CatalogFixture.rule("installers.downloads")
        let downloads = try root(rule)
        func file(_ name: String, depth: Int = 1) -> Candidate {
            CatalogFixture.candidate(
                downloads.appending(path: name, directoryHint: .notDirectory), depth: depth, isDirectory: false)
        }
        let kept = ["a.dmg", "b.PKG", "c.mpkg", "d.iso", "e.xip"].map { file($0) }
        let left = [file("f.zip"), file("g.dmg", depth: 2), file("h.txt")]
        let outcomes = CatalogFixture.evaluate(rule, root: downloads, kept + left)
        #expect(CatalogFixture.findings(outcomes).map(\.url) == kept.map(\.url))
        #expect(outcomes.count == kept.count)
    }

    @Test func partialDownloadsIncludeSafarisFolderKind() throws {
        let rule = try CatalogFixture.rule("installers.partial")
        #expect(rule.tier == .safe)
        let downloads = try root(rule)
        let safari = CatalogFixture.candidate(folder(downloads, "movie.mov.download"))
        let chrome = CatalogFixture.candidate(downloads.appending(path: "a.dmg.crdownload"), isDirectory: false)
        let firefox = CatalogFixture.candidate(downloads.appending(path: "b.zip.part"), isDirectory: false)
        let finished = CatalogFixture.candidate(downloads.appending(path: "c.dmg"), isDirectory: false)
        let outcomes = CatalogFixture.evaluate(rule, root: downloads, [safari, chrome, firefox, finished])
        #expect(CatalogFixture.findings(outcomes).map(\.url) == [safari.url, chrome.url, firefox.url])
        #expect(outcomes.count == 3)
    }

    // MARK: - System Data and the Info rows

    @Test func computedRowsAreTheFiveWithoutAFolder() {
        let ids = Catalog.all.filter { if case .computed = $0.match { true } else { false } }.map(\.id)
        #expect(ids == ["system.snapshots", "system.purgeable", "system.swap", "system.rosetta", "system.unexplained"])
        for rule in Catalog.all {
            if case .computed(let key) = rule.match { #expect(key == rule.id) }
        }
    }

    @Test func rowsWithAFolderMeasureIt() throws {
        let expected: [String: [String]] = [
            "system.spotlight": ["/System/Volumes/Data/.Spotlight-V100/"],
            "system.aiAssets": ["/System/Library/AssetsV2/"],
            "system.updates": ["/Library/Updates/", "/macOS Install Data/"],
            "mail.store": ["~/Library/Mail/"],
            "mail.messagesAttachments": ["~/Library/Messages/Attachments/"],
        ]
        for (id, paths) in expected {
            let rule = try CatalogFixture.rule(id)
            #expect(rule.match == .measureOnly, "\(id)")
            let roots = try CatalogFixture.concreteRoots(rule).map { $0.path(percentEncoded: false).replacing(TestEnv.homePath, with: "~") }
            #expect(roots == paths, "\(id)")
        }
    }

    @Test func everyInfoRowNamesItsFixOrHasNone() throws {
        // The exact text of "Copy Command", from RULE_CATALOG.md §4.10.
        let commands: [String: String] = [
            "system.snapshots": "sudo tmutil thinlocalsnapshots / 999999999999 4",
            "system.spotlight": "sudo mdutil -E /System/Volumes/Data",
        ]
        let panes: [String: String] = [
            "system.snapshots": "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension",
            "system.aiAssets": "x-apple.systempreferences:com.apple.Siri-Settings.extension",
            "mail.messagesAttachments": "x-apple.systempreferences:com.apple.settings.Storage",
        ]
        for rule in Catalog.all {
            #expect(rule.sanctionedCommand == commands[rule.id], "\(rule.id) command")
            #expect(rule.settingsURL?.absoluteString == panes[rule.id], "\(rule.id) settings pane")
            if rule.sanctionedCommand != nil || rule.settingsURL != nil {
                #expect(rule.tier == .info, "\(rule.id): only Info rows point to a fix")
            }
        }
    }

    @Test func sanctionedCommandsAreNeverAnActionOfARule() {
        // "Copy Command" shows text; nothing in the catalog may run it.
        for rule in Catalog.all where rule.sanctionedCommand != nil {
            #expect(rule.action == .none, "\(rule.id)")
        }
    }

    // MARK: - Whole-bundle flag

    @Test func wholeBundleIsDecidedByTheRuleIDAlone() {
        let imposter = Rule(
            id: "installers.other", category: .installers, tier: .review, roots: [],
            match: .glob("*.app"), access: .user, action: .trash, title: "x", explain: "x")
        #expect(!imposter.allowsWholeBundle)
    }
}
