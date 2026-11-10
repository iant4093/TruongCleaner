import CleanerCore
import CleanerScanner
import CleanerTestSupport
import Darwin
import Foundation
import Testing

@testable import CleanerActions

/// One test per rule in `.kiro/steering/safety.md` that `SafetyGate` enforces. Each test fails
/// if its check is removed from the gate. Rules 1, 11, 12 and 14 belong to the lint script and
/// to the executors (task 3.3) and are not covered here.
struct SafetyRulesTests {
    // MARK: Baseline

    @Test func baseline_untouchedItemIsAllowed() async throws {
        try await withHarness { h in
            let file = try h.tree.addFile("home/Library/Caches/a.txt", size: 100)
            let verdict = try await h.verdict(for: file)
            #expect(verdict.isAllowed)
        }
    }

    // MARK: Rule 2: allow-list

    @Test func rule02_pathEscapingTheRootWithDotDotIsDenied() async throws {
        try await withHarness { h in
            let outside = try h.tree.addFile("home/Documents/x.txt")
            let given = URL(filePath: h.caches.path(percentEncoded: false) + "/../../Documents/x.txt")
            let verdict = try await h.verdict(for: outside, scanRoot: h.home, given: given)
            #expect(verdict == .deny(.outsideRoots))
        }
    }

    @Test func rule02_folderWithTheRootsNameAsPrefixIsDenied() async throws {
        try await withHarness { h in
            let lookalike = try h.tree.addFile("home/Library/Caches2/x.txt")
            let verdict = try await h.verdict(for: lookalike, scanRoot: h.home)
            #expect(verdict == .deny(.outsideRoots))
        }
    }

    @Test func rule02_dotDotThatStaysInsideTheRootIsJudgedByItsRealPlace() async throws {
        try await withHarness { h in
            let file = try h.tree.addFile("home/Library/Caches/b/x.txt")
            _ = try h.tree.addDirectory("home/Library/Caches/a")
            let given = URL(filePath: h.caches.path(percentEncoded: false) + "/a/../b/x.txt")
            let verdict = try await h.verdict(for: file, given: given)
            #expect(verdict.isAllowed)
        }
    }

    @Test func rule02_relativeOrNonFileURLIsDenied() async throws {
        try await withHarness { h in
            let file = try h.tree.addFile("home/Library/Caches/a.txt")
            let good = try await h.scanned(file)
            let bad = Finding(
                ruleID: good.ruleID, url: URL(string: "https://example.com/a.txt") ?? file, fsid: good.fsid,
                fileID: good.fileID, allocatedBytes: 0, privateBytes: 0, newestModification: nil,
                isDirectory: false, isSymlink: false, flags: 0, itemCount: 1)
            let verdict = await SafetyGate().authorize(bad, rule: h.rule(), context: h.context())
            #expect(verdict == .deny(.outsideRoots))
        }
    }

    // MARK: Rule 3: protected list and user exclusions win

    @Test func rule03_protectedListWinsInsideARuleRoot() async throws {
        try await withHarness { h in
            let mail = try h.tree.addFile("home/Library/Mail/V10/x.emlx")
            let library = h.home.appending(path: "Library", directoryHint: .isDirectory)
            let verdict = try await h.verdict(
                for: mail, scanRoot: library, context: h.context(roots: [library]))
            #expect(verdict == .deny(.protectedPath(.appleData)))
        }
    }

    @Test func rule03_userExclusionWins() async throws {
        try await withHarness { h in
            let kept = try h.tree.addDirectory("home/Library/Caches/com.keep")
            let inside = try h.tree.addFile("home/Library/Caches/com.keep/x.bin")
            let context = h.context(exclusions: [kept])
            #expect(try await h.verdict(for: inside, context: context) == .deny(.userExcluded))
            #expect(try await h.verdict(for: kept, context: context) == .deny(.userExcluded))
        }
    }

    @Test func rule03_removingAFolderThatHoldsAnExclusionIsDenied() async throws {
        try await withHarness { h in
            let parent = try h.tree.addDirectory("home/Library/Caches/group")
            let excluded = try h.tree.addDirectory("home/Library/Caches/group/keep")
            let verdict = try await h.verdict(for: parent, context: h.context(exclusions: [excluded]))
            #expect(verdict == .deny(.userExcluded))
        }
    }

    // MARK: Rule 4: children only

    @Test func rule04_ruleRootItselfIsDenied() async throws {
        try await withHarness { h in
            let verdict = try await h.verdict(
                for: h.caches, scanRoot: h.home.appending(path: "Library", directoryHint: .isDirectory))
            #expect(verdict == .deny(.isRoot))
        }
    }

    @Test func incident_mole1689_diagnosticReportsFolderItselfIsDenied() async throws {
        try await withHarness { h in
            let reports = try h.tree.addDirectory("home/Library/Logs/DiagnosticReports")
            try h.tree.addFile("home/Library/Logs/DiagnosticReports/old.ips")
            let logs = h.home.appending(path: "Library/Logs", directoryHint: .isDirectory)
            let context = h.context(roots: [reports])
            #expect(try await h.verdict(for: reports, scanRoot: logs, context: context) == .deny(.isRoot))
            let child = h.tree.url(for: "home/Library/Logs/DiagnosticReports/old.ips")
            #expect(try await h.verdict(for: child, scanRoot: logs, context: context).isAllowed)
        }
    }

    @Test func rule04_homeAndLibraryAreNeverDeleted() async throws {
        try await withHarness { h in
            let library = h.home.appending(path: "Library", directoryHint: .isDirectory)
            let context = h.context(roots: [h.home])
            let home = try await h.verdict(for: h.home, scanRoot: h.home, context: context)
            let lib = try await h.verdict(for: library, scanRoot: h.home, context: context)
            #expect(home == .deny(.isRoot))
            #expect(lib == .deny(.isRoot))
        }
    }

    // MARK: Rule 5: no symlinks

    @Test func rule05_symlinkedAncestorIsDenied() async throws {
        try await withHarness { h in
            let target = try h.tree.addFile("home/Documents/x.txt")
            try h.tree.addSymlink(
                "home/Library/Caches/link", destination: h.home.appending(path: "Documents"))
            let given = h.caches.appending(path: "link/x.txt")
            let verdict = try await h.verdict(for: target, scanRoot: h.home, given: given)
            #expect(verdict == .deny(.symlinkAncestor))
        }
    }

    @Test func rule05_symlinkAncestorThatPointsInsideTheRootIsStillDenied() async throws {
        try await withHarness { h in
            let real = try h.tree.addFile("home/Library/Caches/real/x.txt")
            try h.tree.addSymlink("home/Library/Caches/alias", destination: h.caches.appending(path: "real"))
            let given = h.caches.appending(path: "alias/x.txt")
            let verdict = try await h.verdict(for: real, given: given)
            #expect(verdict == .deny(.symlinkAncestor))
        }
    }

    @Test func rule05_symlinkItselfMayBeRemovedAsALinkAndItsTargetIsNeverTouched() async throws {
        try await withHarness { h in
            let target = try h.tree.addFile("home/Documents/keep.txt", size: 10)
            let link = try h.tree.addSymlink("home/Library/Caches/ln", destination: target)
            let verdict = try await h.verdict(for: link)
            #expect(verdict.isAllowed)
            // The link's own identity was checked, not the target's.
            let finding = try await h.scanned(link)
            #expect(finding.isSymlink)
        }
    }

    // MARK: Rule 6: re-check at the door

    @Test func rule06_fileReplacedSinceTheScanIsDenied() async throws {
        try await withHarness { h in
            let file = try h.tree.addFile("home/Library/Caches/a.txt", size: 10)
            let scanned = try await h.scanned(file)
            // Swap in a different file at the same path (rename(2) replaces it).
            let other = try h.tree.addFile("home/Library/Caches/other.tmp", size: 10)
            #expect(rename(other.path(percentEncoded: false), file.path(percentEncoded: false)) == 0)
            let verdict = await SafetyGate().authorize(scanned, rule: h.rule(), context: h.context())
            #expect(verdict == .deny(.changedSinceScan))
        }
    }

    @Test func rule06_itemThatVanishedIsDeniedAsMissing() async throws {
        try await withHarness { h in
            let file = try h.tree.addFile("home/Library/Caches/a.txt", size: 10)
            let scanned = try await h.scanned(file)
            let moved = h.tree.url(for: "home/moved.txt")
            #expect(rename(file.path(percentEncoded: false), moved.path(percentEncoded: false)) == 0)
            let verdict = await SafetyGate().authorize(scanned, rule: h.rule(), context: h.context())
            #expect(verdict == .deny(.missing))
        }
    }

    @Test func rule06_missingParentIsDeniedAsMissing() async throws {
        try await withHarness { h in
            let file = try h.tree.addFile("home/Library/Caches/gone/a.txt", size: 10)
            let scanned = try await h.scanned(file)
            let moved = h.tree.url(for: "home/gone-away")
            #expect(
                rename(h.caches.appending(path: "gone").path(percentEncoded: false), moved.path(percentEncoded: false))
                    == 0)
            let verdict = await SafetyGate().authorize(scanned, rule: h.rule(), context: h.context())
            #expect(verdict == .deny(.missing))
        }
    }

    // MARK: Rule 7: owner closed

    @Test func rule07_runningOwnerIsDenied() async throws {
        try await withHarness { h in
            let file = try h.tree.addFile("home/Library/Caches/a.txt")
            let owner = OwnerSpec.bundleID("com.example.Slack")
            let rule = h.rule(guards: Guards(owners: [owner]))
            let context = h.context(apps: FakeApps(answers: [owner: .running]))
            let verdict = try await h.verdict(for: file, rule: rule, context: context)
            #expect(verdict == .deny(.ownerOpen("com.example.Slack")))
            #expect(DenyReason.ownerOpen("Slack").userMessage == "Slack is open")
        }
    }

    @Test func rule07_runningProcessOwnerIsDenied() async throws {
        try await withHarness { h in
            let file = try h.tree.addFile("home/Library/Caches/a.txt")
            let owner = OwnerSpec.processName("xcodebuild")
            let rule = h.rule(guards: Guards(owners: [owner]))
            let context = h.context(apps: FakeApps(answers: [owner: .running]))
            #expect(try await h.verdict(for: file, rule: rule, context: context) == .deny(.ownerOpen("xcodebuild")))
        }
    }

    @Test func rule07_unknownOwnerStateIsDenied() async throws {
        try await withHarness { h in
            let file = try h.tree.addFile("home/Library/Caches/a.txt")
            let rule = h.rule(guards: Guards(owners: [.bundleID("com.example.Tool")]))
            let context = h.context(apps: FakeApps(fallback: .unknown))
            #expect(try await h.verdict(for: file, rule: rule, context: context) == .deny(.ownerUnknown))
        }
    }

    @Test func rule07_ownerThatIsNotRunningAllows() async throws {
        try await withHarness { h in
            let file = try h.tree.addFile("home/Library/Caches/a.txt")
            let rule = h.rule(guards: Guards(owners: [.bundleID("com.example.Tool"), .processName("tool")]))
            #expect(try await h.verdict(for: file, rule: rule).isAllowed)
        }
    }

    @Test func rule07_childFolderNameIsAskedAsABundleID() async throws {
        try await withHarness { h in
            let item = try h.tree.addFile("home/Library/Caches/com.example.Tool/blob.bin")
            let apps = RecordingApps(answer: .running)
            let rule = h.rule(guards: Guards(owners: [.childNameAsBundleID(stripSuffix: nil)]))
            let verdict = try await h.verdict(for: item, rule: rule, context: h.context(apps: apps))
            #expect(verdict == .deny(.ownerOpen("com.example.Tool")))
            #expect(apps.owners == [.bundleID("com.example.Tool")])
        }
    }

    @Test(arguments: ["plain", "Foo.bar", ".hidden", "a..b"])
    func rule07_childFolderThatIsNotABundleIDHasNoOwner(folder: String) async throws {
        try await withHarness { h in
            let item = try h.tree.addDirectory("home/Library/Caches/\(folder)")
            let apps = RecordingApps(answer: .running)
            let rule = h.rule(guards: Guards(owners: [.childNameAsBundleID(stripSuffix: nil)]))
            let verdict = try await h.verdict(for: item, rule: rule, context: h.context(apps: apps))
            #expect(verdict.isAllowed)
            #expect(apps.owners.isEmpty)
        }
    }

    @Test func incident_mole1854_cacheOfARunningAppIsKept() async throws {
        try await withHarness { h in
            let item = try h.tree.addDirectory("home/Library/Caches/net.example.kitty")
            let apps = FakeApps(answers: [.bundleID("net.example.kitty"): .running])
            let rule = h.rule(guards: Guards(owners: [.childNameAsBundleID(stripSuffix: nil)]))
            let verdict = try await h.verdict(for: item, rule: rule, context: h.context(apps: apps))
            #expect(verdict == .deny(.ownerOpen("net.example.kitty")))
        }
    }

    @Test func incident_mole1584_ownerThatCannotBeCheckedKeepsTheItem() async throws {
        try await withHarness { h in
            let item = try h.tree.addDirectory("home/Library/Caches/com.example.Tool")
            let rule = h.rule(guards: Guards(owners: [.childNameAsBundleID(stripSuffix: nil)]))
            let context = h.context(apps: FakeApps(fallback: .unknown))
            #expect(try await h.verdict(for: item, rule: rule, context: context) == .deny(.ownerUnknown))
            // Nothing is remembered: the next ask gets a fresh answer.
            let open = h.context(apps: FakeApps(fallback: .notRunning))
            #expect(try await h.verdict(for: item, rule: rule, context: open).isAllowed)
        }
    }

    // MARK: Rule 7: owners per root, per wildcard segment, with a suffix

    /// Two browsers, each root carrying only its own browser as owner.
    private func browserRule(_ h: GateHarness) -> (rule: Rule, chrome: URL, brave: URL) {
        let chromeSpec = RootSpec(
            base: .home, components: ["Library", "Caches", "Google", "Chrome"],
            owners: [.bundleID("com.google.Chrome")])
        let braveSpec = RootSpec(
            base: .home, components: ["Library", "Caches", "BraveSoftware", "Brave-Browser"],
            owners: [.bundleID("com.brave.Browser")])
        let rule = h.rule(roots: [chromeSpec, braveSpec])
        return (
            rule, h.caches.appending(path: "Google/Chrome", directoryHint: .isDirectory),
            h.caches.appending(path: "BraveSoftware/Brave-Browser", directoryHint: .isDirectory)
        )
    }

    @Test func rule07_runningChromeBlocksOnlyChromesCaches() async throws {
        try await withHarness { h in
            let (rule, chromeRoot, braveRoot) = browserRule(h)
            let chrome = try h.tree.addFile("home/Library/Caches/Google/Chrome/Default/blob.bin")
            let brave = try h.tree.addFile("home/Library/Caches/BraveSoftware/Brave-Browser/Default/blob.bin")
            let context = h.context(
                roots: [chromeRoot, braveRoot],
                apps: FakeApps(answers: [.bundleID("com.google.Chrome"): .running]))

            let chromeVerdict = try await h.verdict(
                for: chrome.deletingLastPathComponent(), scanRoot: chromeRoot, rule: rule, context: context)
            let braveVerdict = try await h.verdict(
                for: brave.deletingLastPathComponent(), scanRoot: braveRoot, rule: rule, context: context)
            #expect(chromeVerdict == .deny(.ownerOpen("com.google.Chrome")))
            #expect(braveVerdict.isAllowed)
        }
    }

    @Test func rule07_theOtherBrowserRunningBlocksTheOtherRoot() async throws {
        try await withHarness { h in
            let (rule, chromeRoot, braveRoot) = browserRule(h)
            let chrome = try h.tree.addDirectory("home/Library/Caches/Google/Chrome/Default")
            let brave = try h.tree.addDirectory("home/Library/Caches/BraveSoftware/Brave-Browser/Default")
            let context = h.context(
                roots: [chromeRoot, braveRoot],
                apps: FakeApps(answers: [.bundleID("com.brave.Browser"): .running]))
            #expect(try await h.verdict(for: chrome, scanRoot: chromeRoot, rule: rule, context: context).isAllowed)
            #expect(
                try await h.verdict(for: brave, scanRoot: braveRoot, rule: rule, context: context)
                    == .deny(.ownerOpen("com.brave.Browser")))
        }
    }

    @Test func rule07_rootOwnersAndRuleOwnersAreBothChecked() async throws {
        try await withHarness { h in
            let (_, chromeRoot, braveRoot) = browserRule(h)
            let item = try h.tree.addDirectory("home/Library/Caches/Google/Chrome/Default")
            // No root specs with owners on the rule: the owner comes from the rule and the context.
            let rule = h.rule(guards: Guards(owners: [.processName("helper")]))
            let apps = FakeApps(answers: [
                .processName("helper"): .running, .bundleID("com.google.Chrome"): .running,
            ])
            let context = h.context(
                roots: [chromeRoot, braveRoot], apps: apps,
                rootOwners: [chromeRoot: [.bundleID("com.google.Chrome")]])
            #expect(
                try await h.verdict(for: item, scanRoot: chromeRoot, rule: rule, context: context)
                    == .deny(.ownerOpen("helper")))
            let quiet = h.context(
                roots: [chromeRoot, braveRoot],
                apps: FakeApps(answers: [.bundleID("com.google.Chrome"): .running]),
                rootOwners: [chromeRoot: [.bundleID("com.google.Chrome")]])
            #expect(
                try await h.verdict(for: item, scanRoot: chromeRoot, rule: rule, context: quiet)
                    == .deny(.ownerOpen("com.google.Chrome")))
            // A root owner entry for another root does not apply here.
            let other = h.context(
                roots: [chromeRoot, braveRoot],
                apps: FakeApps(answers: [.bundleID("com.google.Chrome"): .running]),
                rootOwners: [braveRoot: [.bundleID("com.google.Chrome")]])
            #expect(try await h.verdict(for: item, scanRoot: chromeRoot, rule: rule, context: other).isAllowed)
        }
    }

    @Test func rule07_rootOwnerThatCannotBeCheckedKeepsTheItem() async throws {
        try await withHarness { h in
            let (rule, chromeRoot, braveRoot) = browserRule(h)
            let item = try h.tree.addDirectory("home/Library/Caches/Google/Chrome/Default")
            let context = h.context(roots: [chromeRoot, braveRoot], apps: FakeApps(fallback: .unknown))
            #expect(
                try await h.verdict(for: item, scanRoot: chromeRoot, rule: rule, context: context)
                    == .deny(.ownerUnknown))
        }
    }

    private static let containerSpec = RootSpec(
        base: .home, components: ["Library", "Containers", "*", "Data", "Library", "Caches"])

    @Test func rule07_containerFolderNameIsAskedAsABundleID() async throws {
        try await withHarness { h in
            let rule = h.rule(
                guards: Guards(owners: [.rootSegmentAsBundleID(index: 2)]), roots: [Self.containerSpec])
            let root = h.tree.url(for: "home/Library/Containers/com.example.Tool/Data/Library/Caches")
            let item = try h.tree.addFile("home/Library/Containers/com.example.Tool/Data/Library/Caches/blob.bin")
            let apps = RecordingApps(answer: .running)
            let verdict = try await h.verdict(
                for: item, scanRoot: root, rule: rule, context: h.context(roots: [root], apps: apps))
            #expect(verdict == .deny(.ownerOpen("com.example.Tool")))
            #expect(apps.owners == [.bundleID("com.example.Tool")])

            // The app is closed: the same item is allowed.
            let quiet = h.context(roots: [root], apps: FakeApps(fallback: .notRunning))
            #expect(try await h.verdict(for: item, scanRoot: root, rule: rule, context: quiet).isAllowed)
        }
    }

    @Test func rule07_containerFolderThatIsNotABundleIDHasNoOwner() async throws {
        try await withHarness { h in
            let rule = h.rule(
                guards: Guards(owners: [.rootSegmentAsBundleID(index: 2)]), roots: [Self.containerSpec])
            let root = h.tree.url(for: "home/Library/Containers/plain/Data/Library/Caches")
            let item = try h.tree.addFile("home/Library/Containers/plain/Data/Library/Caches/blob.bin")
            let apps = RecordingApps(answer: .running)
            let verdict = try await h.verdict(
                for: item, scanRoot: root, rule: rule, context: h.context(roots: [root], apps: apps))
            #expect(verdict.isAllowed)
            #expect(apps.owners.isEmpty)
        }
    }

    @Test func rule07_rootSegmentThatCannotBeFoundKeepsTheItem() async throws {
        try await withHarness { h in
            // The rule's root specs do not fit the root the item lies under: the segment is unknown.
            let rule = h.rule(guards: Guards(owners: [.rootSegmentAsBundleID(index: 2)]))
            let item = try h.tree.addFile("home/Library/Caches/blob.bin")
            let apps = RecordingApps(answer: .notRunning)
            #expect(
                try await h.verdict(for: item, rule: rule, context: h.context(apps: apps)) == .deny(.ownerUnknown))
            #expect(apps.owners.isEmpty)
        }
    }

    @Test func rule02_aRootTheRuleExcludesBySegmentIsNotOneOfItsRoots() async throws {
        try await withHarness { h in
            let rule = h.rule(
                guards: Guards(excludeRootSegments: ["com.apple.*"]), roots: [Self.containerSpec])
            let apple = h.tree.url(for: "home/Library/Containers/com.apple.Notes/Data/Library/Caches")
            let other = h.tree.url(for: "home/Library/Containers/com.example.Tool/Data/Library/Caches")
            let appleItem = try h.tree.addFile("home/Library/Containers/com.apple.Notes/Data/Library/Caches/a.bin")
            let otherItem = try h.tree.addFile("home/Library/Containers/com.example.Tool/Data/Library/Caches/a.bin")
            let context = h.context(roots: [apple, other])
            #expect(
                try await h.verdict(for: appleItem, scanRoot: apple, rule: rule, context: context)
                    == .deny(.outsideRoots))
            #expect(try await h.verdict(for: otherItem, scanRoot: other, rule: rule, context: context).isAllowed)
        }
    }

    @Test func rule07_savedStateFolderNameLosesItsSuffixBeforeTheOwnerLookup() async throws {
        try await withHarness { h in
            let saved = try h.tree.addDirectory("home/Library/Saved Application State")
            let item = try h.tree.addDirectory("home/Library/Saved Application State/com.example.App.savedState")
            let rule = h.rule(guards: Guards(owners: [.childNameAsBundleID(stripSuffix: ".savedState")]))
            let apps = RecordingApps(answer: .running)
            let context = h.context(roots: [saved], apps: apps)
            #expect(
                try await h.verdict(for: item, scanRoot: saved, rule: rule, context: context)
                    == .deny(.ownerOpen("com.example.App")))
            #expect(apps.owners == [.bundleID("com.example.App")])

            // Two parts after stripping is not a bundle ID: no owner, nothing asked.
            let short = try h.tree.addDirectory("home/Library/Saved Application State/a.b.savedState")
            let quiet = RecordingApps(answer: .running)
            let allowed = try await h.verdict(
                for: short, scanRoot: saved, rule: rule, context: h.context(roots: [saved], apps: quiet))
            #expect(allowed.isAllowed)
            #expect(quiet.owners.isEmpty)
        }
    }

    @Test func rule07_theSameOwnerIsAskedOnce() async throws {
        try await withHarness { h in
            let spec = RootSpec(
                base: .home, components: ["Library", "Caches"], owners: [.bundleID("com.example.Tool")])
            let rule = h.rule(guards: Guards(owners: [.bundleID("com.example.Tool")]), roots: [spec])
            let item = try h.tree.addFile("home/Library/Caches/a.txt")
            let apps = RecordingApps(answer: .notRunning)
            #expect(try await h.verdict(for: item, rule: rule, context: h.context(apps: apps)).isAllowed)
            #expect(apps.owners == [.bundleID("com.example.Tool")])
        }
    }

    // MARK: Rule 8: open files

    @Test func rule08_itemWithAnOpenFileIsDenied() async throws {
        try await withHarness { h in
            let file = try h.tree.addFile("home/Library/Caches/a.txt")
            let context = h.context(files: FakeFiles(answer: true))
            #expect(try await h.verdict(for: file, context: context) == .deny(.openFiles))
        }
    }

    @Test func rule08_openFileCheckThatFailsIsDenied() async throws {
        try await withHarness { h in
            let file = try h.tree.addFile("home/Library/Caches/a.txt")
            let context = h.context(files: FakeFiles(answer: nil))
            #expect(try await h.verdict(for: file, context: context) == .deny(.openFilesUnknown))
        }
    }

    // MARK: Rule 9: unknown means keep

    @Test func rule09_unreadableItemFolderMakesTheAgeUnknown() async throws {
        try await withHarness { h in
            let folder = try h.tree.addDirectory("home/Library/Caches/locked")
            try h.tree.setModified("home/Library/Caches/locked", to: h.ago(days: 90))
            let finding = try await h.scanned(folder)
            try h.tree.setPermissions("home/Library/Caches/locked", mode: 0)
            let rule = h.rule(guards: Guards(minAge: .seconds(7 * 86_400)))
            let verdict = await SafetyGate().authorize(finding, rule: rule, context: h.context())
            #expect(verdict == .deny(.unknownAge))
        }
    }

    @Test func rule09_unreadableSubfolderMakesTheAgeUnknown() async throws {
        try await withHarness { h in
            let folder = try h.tree.addDirectory("home/Library/Caches/outer")
            try h.tree.addFile("home/Library/Caches/outer/inner/old.bin", modified: h.ago(days: 90))
            let finding = try await h.scanned(folder)
            try h.tree.setPermissions("home/Library/Caches/outer/inner", mode: 0)
            let rule = h.rule(guards: Guards(minAge: .seconds(7 * 86_400)))
            let verdict = await SafetyGate().authorize(finding, rule: rule, context: h.context())
            #expect(verdict == .deny(.unknownAge))
        }
    }

    @Test func rule09_unreadableParentIsAProbeFailureNotAnAllow() async throws {
        try await withHarness { h in
            let file = try h.tree.addFile("home/Library/Caches/dir/a.txt")
            let finding = try await h.scanned(file)
            try h.tree.setPermissions("home/Library/Caches/dir", mode: 0)
            let verdict = await SafetyGate().authorize(finding, rule: h.rule(), context: h.context())
            guard case .deny(.probeFailed(let detail)) = verdict else {
                Issue.record("Expected probeFailed, got \(verdict)")
                return
            }
            // The detail never contains a path.
            #expect(!detail.contains(h.tree.root.lastPathComponent))
        }
    }

    // MARK: Rule 10: macOS protection

    @Test(arguments: [Int32(UF_IMMUTABLE), Int32(UF_APPEND)])
    func rule10_flaggedFileIsProtectedByMacOS(flag: Int32) async throws {
        try await withHarness { h in
            let file = try h.tree.addFile("home/Library/Caches/flagged.bin")
            setFlags(file, flag)
            defer { setFlags(file, 0) }
            #expect(try await h.verdict(for: file) == .deny(.macOSProtected))
        }
    }

    @Test func rule10_folderInsideAnImmutableParentIsProtectedByMacOS() async throws {
        try await withHarness { h in
            let group = try h.tree.addDirectory("home/Library/Caches/group")
            let sub = try h.tree.addDirectory("home/Library/Caches/group/sub")
            setFlags(group, Int32(UF_IMMUTABLE))
            defer { setFlags(group, 0) }
            #expect(try await h.verdict(for: sub) == .deny(.macOSProtected))
        }
    }

    @Test func rule10_everySystemFlagIsInTheMask() {
        let flags: [UInt32] = [
            UInt32(SF_RESTRICTED), UInt32(SF_NOUNLINK), UInt32(SF_IMMUTABLE),
            UInt32(UF_IMMUTABLE), UInt32(SF_APPEND), UInt32(UF_APPEND),
        ]
        for flag in flags {
            #expect(GateSystem.isMacOSProtected(flags: flag), "flag \(flag) must protect")
        }
        #expect(!GateSystem.isMacOSProtected(flags: 0))
        #expect(!GateSystem.isMacOSProtected(flags: UInt32(UF_HIDDEN)))
        #expect(!GateSystem.isMacOSProtected(flags: UInt32(UF_NODUMP)))
    }

    @Test func incident_pearcleaner616_systemOwnedItemIsKeptNotMovedToTheTrash() async throws {
        try await withHarness { h in
            let folder = try h.tree.addDirectory("home/Library/Caches/system-owned")
            setFlags(folder, Int32(UF_IMMUTABLE))
            defer { setFlags(folder, 0) }
            let verdict = try await h.verdict(for: folder)
            #expect(verdict == .deny(.macOSProtected))
            #expect(!verdict.isAllowed)
            #expect(DenyReason.macOSProtected.userMessage == "Protected by macOS")
        }
    }

    // MARK: Rule 13: no bundle edits

    static let bundleExtensions = [
        "app", "framework", "bundle", "plugin", "appex", "kext", "xpc",
        "qlgenerator", "prefPane", "saver", "mdimporter", "driver",
    ]

    @Test(arguments: bundleExtensions)
    func rule13_bundleAndItsContentsAreDenied(ext: String) async throws {
        try await withHarness { h in
            let inner = try h.tree.addFile("home/Library/Caches/Foo.\(ext)/Contents/x.bin")
            try h.tree.addFile("home/Library/Caches/Foo.\(ext)/Contents/Info.plist")
            let bundle = h.tree.url(for: "home/Library/Caches/Foo.\(ext)")
            #expect(try await h.verdict(for: bundle) == .deny(.insideBundle))
            #expect(try await h.verdict(for: inner) == .deny(.insideBundle))
        }
    }

    @Test func rule13_wholeAppMayGoOnlyWhenTheRuleAllowsIt() async throws {
        try await withHarness { h in
            let installers = try h.tree.addDirectory("home/Installers")
            let inner = try h.tree.addFile("home/Installers/Install Foo.app/Contents/x.bin")
            try h.tree.addFile("home/Installers/Install Foo.app/Contents/Info.plist")
            let app = h.tree.url(for: "home/Installers/Install Foo.app")
            let framework = h.tree.url(for: "home/Installers/Foo.framework")
            try h.tree.addFile("home/Installers/Foo.framework/Info.plist")

            let allowing = h.context(roots: [installers], allowWholeBundle: true)
            #expect(try await h.verdict(for: app, scanRoot: installers, context: allowing).isAllowed)
            #expect(try await h.verdict(for: inner, scanRoot: installers, context: allowing) == .deny(.insideBundle))
            #expect(
                try await h.verdict(for: framework, scanRoot: installers, context: allowing) == .deny(.insideBundle))

            let normal = h.context(roots: [installers])
            #expect(try await h.verdict(for: app, scanRoot: installers, context: normal) == .deny(.insideBundle))
        }
    }

    @Test(arguments: [
        "Contents/Info.plist", "Info.plist", "Contents/_CodeSignature/CodeResources",
    ])
    func rule13_anyOneBundleMarkerMakesAFolderABundle(marker: String) async throws {
        try await withHarness { h in
            let inner = try h.tree.addFile("home/Library/Caches/Foo.app/Resources/x.bin")
            try h.tree.addFile("home/Library/Caches/Foo.app/\(marker)")
            let bundle = h.tree.url(for: "home/Library/Caches/Foo.app")
            #expect(try await h.verdict(for: bundle) == .deny(.insideBundle))
            #expect(try await h.verdict(for: inner) == .deny(.insideBundle))
        }
    }

    @Test func rule13_aCacheFolderNamedLikeABundleIDIsNotABundle() async throws {
        try await withHarness { h in
            // "com.example.App" has the extension "App", which is a bundle extension.
            let inner = try h.tree.addFile("home/Library/Caches/com.example.App/data/blob.bin")
            let folder = h.tree.url(for: "home/Library/Caches/com.example.App")
            #expect(try await h.verdict(for: folder).isAllowed)
            #expect(try await h.verdict(for: inner).isAllowed)
        }
    }

    @Test func rule13_aFileOrEmptyFolderWithABundleNameIsNotABundle() async throws {
        try await withHarness { h in
            let file = try h.tree.addFile("home/Library/Caches/Foo.framework")
            let empty = try h.tree.addDirectory("home/Library/Caches/Bar.bundle")
            #expect(try await h.verdict(for: file).isAllowed)
            #expect(try await h.verdict(for: empty).isAllowed)
        }
    }

    @Test func rule13_aRealBundleAboveTheItemDeniesEvenDeepInside() async throws {
        try await withHarness { h in
            let deep = try h.tree.addFile("home/Library/Caches/Foo.app/Contents/Resources/deep/er/x.bin")
            try h.tree.addFile("home/Library/Caches/Foo.app/Contents/Info.plist")
            #expect(try await h.verdict(for: deep) == .deny(.insideBundle))
        }
    }

    @Test func rule13_aBundleThatCannotBeInspectedIsKept() async throws {
        try await withHarness { h in
            let bundle = try h.tree.addDirectory("home/Library/Caches/Foo.app")
            try h.tree.addFile("home/Library/Caches/Foo.app/Contents/Info.plist")
            let finding = try await h.scanned(bundle)
            try h.tree.setPermissions("home/Library/Caches/Foo.app", mode: 0)
            let verdict = await SafetyGate().authorize(finding, rule: h.rule(), context: h.context())
            guard case .deny(.probeFailed) = verdict else {
                Issue.record("Expected probeFailed, got \(verdict)")
                return
            }
        }
    }

    // MARK: Rule 15: dry run is the real run

    @Test func rule15_previewAndCleanGetTheSameVerdict() async throws {
        try await withHarness { h in
            let file = try h.tree.addFile("home/Library/Caches/com.example.Tool/a.bin")
            let allowed = try await h.scanned(file)
            let rule = h.rule(guards: Guards(owners: [.childNameAsBundleID(stripSuffix: nil)]))
            let gate = SafetyGate()

            let quiet = h.context()
            let preview = await gate.authorize(allowed, rule: rule, context: quiet)
            let clean = await gate.authorize(allowed, rule: rule, context: quiet)
            #expect(preview.isAllowed)
            #expect(preview == clean)

            let busy = h.context(apps: FakeApps(fallback: .running))
            let deniedPreview = await gate.authorize(allowed, rule: rule, context: busy)
            let deniedClean = await gate.authorize(allowed, rule: rule, context: busy)
            #expect(deniedPreview == .deny(.ownerOpen("com.example.Tool")))
            #expect(deniedPreview == deniedClean)
        }
    }

    // MARK: Rule 16: Info rows never delete

    @Test(arguments: [
        (Tier.info, Action.none), (Tier.info, Action.trash), (Tier.safe, Action.none), (Tier.review, Action.none),
    ])
    func rule16_infoRuleOrRuleWithoutActionNeverAllows(tier: Tier, action: Action) async throws {
        try await withHarness { h in
            let file = try h.tree.addFile("home/Library/Caches/a.txt")
            let verdict = try await h.verdict(for: file, rule: h.rule(tier: tier, action: action))
            #expect(verdict == .deny(.infoRule))
        }
    }

    @Test func deletePermanentlyIsJudgedLikeTrash() async throws {
        try await withHarness { h in
            let file = try h.tree.addFile("home/Library/Caches/a.txt")
            let rule = h.rule(action: .deletePermanently)
            #expect(try await h.verdict(for: file, rule: rule).isAllowed)
            // Every other check still applies.
            let busy = h.context(files: FakeFiles(answer: true))
            #expect(try await h.verdict(for: file, rule: rule, context: busy) == .deny(.openFiles))
            let info = h.rule(tier: .info, action: .deletePermanently)
            #expect(try await h.verdict(for: file, rule: info) == .deny(.infoRule))
        }
    }

    @Test func rule16_infoRuleIsDecidedBeforeTheFileSystemIsTouched() async throws {
        try await withHarness { h in
            let finding = Finding(
                ruleID: "test.rule", url: h.caches.appending(path: "does-not-exist"), fsid: 0, fileID: 0,
                allocatedBytes: 0, privateBytes: 0, newestModification: nil, isDirectory: false, isSymlink: false,
                flags: 0, itemCount: 1)
            let verdict = await SafetyGate().authorize(finding, rule: h.rule(tier: .info), context: h.context())
            #expect(verdict == .deny(.infoRule))
        }
    }

    // MARK: Age and keep-newest (rule 3 of RULE_CATALOG: guards still hold at the door)

    @Test func minAge_oldFileIsAllowedAndRecentFileIsTooNew() async throws {
        try await withHarness { h in
            let old = try h.tree.addFile("home/Library/Caches/old.bin", modified: h.ago(days: 30))
            let fresh = try h.tree.addFile("home/Library/Caches/fresh.bin", modified: h.ago(days: 1))
            let rule = h.rule(guards: Guards(minAge: .seconds(7 * 86_400)))
            #expect(try await h.verdict(for: old, rule: rule).isAllowed)
            #expect(try await h.verdict(for: fresh, rule: rule) == .deny(.tooNew))
        }
    }

    @Test func minAge_folderIsJudgedByTheNewestFileInside() async throws {
        try await withHarness { h in
            try h.tree.addFile("home/Library/Caches/oldDir/a.bin", modified: h.ago(days: 30))
            try h.tree.addFile("home/Library/Caches/mixedDir/a.bin", modified: h.ago(days: 30))
            try h.tree.addFile("home/Library/Caches/mixedDir/b.bin", modified: h.ago(days: 1))
            try h.tree.setModified("home/Library/Caches/oldDir", to: h.ago(days: 30))
            try h.tree.setModified("home/Library/Caches/mixedDir", to: h.ago(days: 30))
            let rule = h.rule(guards: Guards(minAge: .seconds(7 * 86_400)))
            let oldDir = h.tree.url(for: "home/Library/Caches/oldDir")
            let mixed = h.tree.url(for: "home/Library/Caches/mixedDir")
            #expect(try await h.verdict(for: oldDir, rule: rule).isAllowed)
            #expect(try await h.verdict(for: mixed, rule: rule) == .deny(.tooNew))
        }
    }

    @Test func keepNewest_theNewestSiblingsAreDeniedAtTheDoor() async throws {
        try await withHarness { h in
            let names = ["d1", "d2", "d3", "d4"]
            for name in names { try h.tree.addDirectory("home/Library/Caches/\(name)") }
            // Set dates after all children exist; adding children changes a folder's date.
            for (index, name) in names.enumerated() {
                try h.tree.setModified("home/Library/Caches/\(name)", to: h.ago(days: Double(40 - index * 10)))
            }
            let rule = h.rule(guards: Guards(keepNewest: 2))
            var results: [String: Verdict] = [:]
            for name in names {
                results[name] = try await h.verdict(for: h.tree.url(for: "home/Library/Caches/\(name)"), rule: rule)
            }
            #expect(results["d4"] == .deny(.keepNewest))
            #expect(results["d3"] == .deny(.keepNewest))
            #expect(results["d2"]?.isAllowed == true)
            #expect(results["d1"]?.isAllowed == true)
        }
    }

    // MARK: Incidents

    @Test func incident_mole823_claudeProjectMemoryIsProtected() async throws {
        try await withHarness { h in
            let memory = try h.tree.addFile("home/.claude/projects/p/memory/x.md")
            let claude = h.home.appending(path: ".claude", directoryHint: .isDirectory)
            let verdict = try await h.verdict(
                for: memory, scanRoot: claude, context: h.context(roots: [claude]))
            #expect(verdict == .deny(.protectedPath(.agentState)))
        }
    }

    // MARK: Messages and storage

    private static let allReasons: [DenyReason] = [
        .infoRule, .userExcluded, .outsideRoots, .isRoot, .symlinkAncestor, .insideBundle, .macOSProtected,
        .changedSinceScan, .missing, .tooNew, .unknownAge, .keepNewest, .ownerOpen("Slack"), .ownerUnknown,
        .openFiles, .openFilesUnknown, .editedAfterDownload, .trackedByGit, .notAppleInstaller,
        .probeFailed("getattrlist: Permission denied (errno 13)"),
        .protectedPath(.system), .protectedPath(.root), .protectedPath(.appleData),
        .protectedPath(.syncAndIdentity), .protectedPath(.fragileAppleCache), .protectedPath(.agentState),
        .protectedPath(.liveStore), .protectedPath(.licensedVendor), .protectedPath(.passwordManager),
        .protectedPath(.userExcluded),
    ]

    @Test(arguments: allReasons)
    func denyReason_hasAPlainMessageAndSurvivesJSON(reason: DenyReason) throws {
        #expect(!reason.userMessage.isEmpty)
        let data = try JSONEncoder().encode(reason)
        #expect(try JSONDecoder().decode(DenyReason.self, from: data) == reason)
    }

    @Test func denyReason_unknownKindFailsToDecode() {
        let json = Data(#"{"kind":"somethingNew"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(DenyReason.self, from: json) }
    }
}
