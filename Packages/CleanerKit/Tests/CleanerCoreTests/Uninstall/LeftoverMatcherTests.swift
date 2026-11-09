import Foundation
import Testing

@testable import CleanerCore

/// One test or more for each row of the `docs/UNINSTALLER.md` §3 table, and for each extra rule.
struct LeftoverMatcherTests {
    private typealias Fixtures = UninstallFixtures

    private static func entry(_ name: String, directory: Bool = true) -> LeftoverEntry {
        LeftoverEntry(name: name, isDirectory: directory)
    }

    private static func inside(_ app: String = "/Applications/Foo.app") -> String { app + "/Contents/MacOS/Foo" }

    // MARK: Table rows

    @Test func nameEqualToTheBundleIDIsSafe() {
        let matches = Fixtures.match(
            Fixtures.app(),
            [Fixtures.user(.caches): [Self.entry("com.example.Foo"), Self.entry("com.example.Bar")]])
        #expect(Fixtures.names(matches) == ["com.example.Foo"])
        #expect(matches.candidates.first?.tier == .safe)
        #expect(matches.candidates.first?.evidence == .exactBundleID("com.example.Foo"))
    }

    @Test(arguments: [
        "com.example.Foo.plist", "com.example.Foo.savedState", "com.example.Foo.helper.plist",
        "com.example.Foo.binarycookies",
    ])
    func nameWithTheBundleIDAndASuffixIsSafe(name: String) {
        let matches = Fixtures.match(
            Fixtures.app(), [Fixtures.user(.preferences): [Self.entry(name, directory: false)]])
        #expect(Fixtures.names(matches) == [name])
        #expect(matches.candidates.first?.tier == .safe)
        #expect(matches.candidates.first?.evidence == .bundleIDPrefix("com.example.Foo"))
    }

    @Test func containerIsFoundByItsMetadataIdentifier() {
        let uuid = "6F1B0C52-0000-4000-8000-0123456789AB"
        let matches = Fixtures.match(
            Fixtures.app(),
            [
                Fixtures.user(.containers): [
                    LeftoverEntry(name: uuid, metadataIdentifier: "com.example.Foo"),
                    LeftoverEntry(name: "7F1B0C52-0000-4000-8000-0123456789AB", metadataIdentifier: "com.example.Foo.Widget"),
                    LeftoverEntry(name: "8F1B0C52-0000-4000-8000-0123456789AB", metadataIdentifier: "com.example.Bar"),
                    LeftoverEntry(name: "9F1B0C52-0000-4000-8000-0123456789AB", metadataIdentifier: nil),
                ]
            ])
        #expect(Fixtures.names(matches) == [uuid, "7F1B0C52-0000-4000-8000-0123456789AB"])
        #expect(matches.candidates.allSatisfy { $0.tier == .safe })
    }

    @Test func metadataIdentifierIsOnlyReadInContainers() {
        let matches = Fixtures.match(
            Fixtures.app(),
            [Fixtures.user(.caches): [LeftoverEntry(name: "cache-1", metadataIdentifier: "com.example.Foo")]])
        #expect(matches.candidates.isEmpty)
    }

    @Test func groupContainerNamedAfterTheBundleIDIsReview() {
        let matches = Fixtures.match(
            Fixtures.app(),
            [Fixtures.user(.groupContainers): [Self.entry("group.com.example.Foo"), Self.entry("group.com.example.Foo.shared")]])
        #expect(Fixtures.names(matches) == ["group.com.example.Foo", "group.com.example.Foo.shared"])
        #expect(matches.candidates.allSatisfy { $0.tier == .review })
    }

    @Test func groupContainerWithTheTeamIDIsReview() {
        let matches = Fixtures.match(
            Fixtures.app(team: "ABCDE12345"),
            [Fixtures.user(.groupContainers): [Self.entry("ABCDE12345.com.example"), Self.entry("ZZZZZ99999.other")]])
        #expect(Fixtures.names(matches) == ["ABCDE12345.com.example"])
        #expect(matches.candidates.first?.tier == .review)
    }

    @Test func teamGroupContainerIsDroppedWhenAnotherInstalledAppHasTheSameTeam() {
        // Word and Excel share one group container. Removing Word must not offer it.
        let word = Fixtures.app("com.example.Word", name: "Word", executable: "Word", team: "UBF8T346G9")
        let excel = Fixtures.other("com.example.Excel", name: "Excel", team: "UBF8T346G9")
        let matches = Fixtures.match(
            word, others: [excel],
            [Fixtures.user(.groupContainers): [Self.entry("UBF8T346G9.Office")]])
        #expect(matches.candidates.isEmpty)
    }

    @Test func teamGroupContainerNeedsACompleteInventory() {
        let matches = Fixtures.match(
            Fixtures.app(team: "ABCDE12345"), complete: false,
            [Fixtures.user(.groupContainers): [Self.entry("ABCDE12345.com.example")]])
        #expect(matches.candidates.isEmpty)
    }

    @Test func launchAgentNeedsBothALabelAndAProgramInsideTheApp() {
        let job = LaunchJob(label: "com.example.Foo.agent", programs: [Self.inside()])
        let matches = Fixtures.match(
            Fixtures.app(),
            [Fixtures.user(.launchAgents): [LeftoverEntry(name: "com.example.Foo.agent.plist", isDirectory: false, launchJob: job)]])
        #expect(Fixtures.names(matches) == ["com.example.Foo.agent.plist"])
        #expect(matches.candidates.first?.tier == .safe)
        #expect(matches.candidates.first?.evidence == .launchJob(label: "com.example.Foo.agent"))
    }

    @Test(arguments: [
        // Label fits, program is elsewhere.
        LaunchJob(label: "com.example.Foo.agent", programs: ["/usr/local/bin/foo"]),
        // Program is inside, label is another app's.
        LaunchJob(label: "com.other.Bar.agent", programs: ["/Applications/Foo.app/Contents/MacOS/Foo"]),
        // No program at all.
        LaunchJob(label: "com.example.Foo.agent", programs: []),
        // No label.
        LaunchJob(label: nil, programs: ["/Applications/Foo.app/Contents/MacOS/Foo"]),
        // One of two programs is outside.
        LaunchJob(label: "com.example.Foo.agent", programs: ["/Applications/Foo.app/Contents/MacOS/Foo", "/bin/sh"]),
        // Escapes the bundle with "..".
        LaunchJob(label: "com.example.Foo.agent", programs: ["/Applications/Foo.app/../Bar.app/Contents/MacOS/Bar"]),
        // Not absolute.
        LaunchJob(label: "com.example.Foo.agent", programs: ["Foo.app/Contents/MacOS/Foo"]),
        // The bundle folder itself is not "inside".
        LaunchJob(label: "com.example.Foo.agent", programs: ["/Applications/Foo.app"]),
        // A different app whose name starts the same.
        LaunchJob(label: "com.example.Foo.agent", programs: ["/Applications/Foo.app.old/Contents/MacOS/Foo"]),
    ])
    func launchAgentWithoutBothKindsOfEvidenceIsNotOffered(job: LaunchJob) {
        let matches = Fixtures.match(
            Fixtures.app(),
            [Fixtures.user(.launchAgents): [LeftoverEntry(name: "com.example.Foo.agent.plist", isDirectory: false, launchJob: job)]])
        #expect(matches.candidates.isEmpty)
    }

    @Test func launchAgentNamedLikeTheAppIsNotMatchedByName() {
        // The plist's file name fits, but a launch job needs its label and program, not its file name.
        let matches = Fixtures.match(
            Fixtures.app(),
            [Fixtures.user(.launchAgents): [
                LeftoverEntry(name: "com.example.Foo.plist", isDirectory: false),
                LeftoverEntry(name: "Foo", isDirectory: false),
            ]])
        #expect(matches.candidates.isEmpty)
    }

    @Test func launchProgramInsideTheAppIsRecognisedThroughTheDataVolumePath() {
        let job = LaunchJob(label: "com.example.Foo.agent", programs: ["/System/Volumes/Data/Applications/Foo.app/Contents/MacOS/Foo"])
        let matches = Fixtures.match(
            Fixtures.app(),
            [Fixtures.user(.launchAgents): [LeftoverEntry(name: "a.plist", isDirectory: false, launchJob: job)]])
        #expect(Fixtures.names(matches) == ["a.plist"])
    }

    @Test func nameEqualToTheAppNameIsReviewAndNotSelected() {
        let app = Fixtures.app(name: "Foo Pro", displayName: "Foo Professional", executable: "foopro")
        let matches = Fixtures.match(
            app,
            [Fixtures.user(.applicationSupport): [
                Self.entry("Foo Pro"), Self.entry("Foo Professional"), Self.entry("FOOPRO"), Self.entry("Other"),
            ]])
        #expect(Set(Fixtures.names(matches)) == ["Foo Pro", "Foo Professional", "FOOPRO"])
        #expect(matches.candidates.allSatisfy { $0.tier == .review })
        #expect(matches.candidates.allSatisfy { if case .appName = $0.evidence { true } else { false } })
    }

    @Test func nameOnlyMatchNeedsAtLeastFourCharacters() {
        let app = Fixtures.app("com.example.Pro", name: "Pro", executable: "Pro")
        let matches = Fixtures.match(app, [Fixtures.user(.applicationSupport): [Self.entry("Pro")]])
        #expect(matches.candidates.isEmpty)
        let four = Fixtures.app("com.example.Abcd", name: "Abcd", executable: "Abcd")
        #expect(Fixtures.names(Fixtures.match(four, [Fixtures.user(.applicationSupport): [Self.entry("Abcd")]])) == ["Abcd"])
    }

    // MARK: Extra rules

    @Test func extraRule1_shortBundleIDsMatchOnlyByEquality() {
        // Lemon's bug: a 2-part bundle ID matched every launch agent that started with it.
        let short = Fixtures.app("com.x", name: "X", executable: "x")
        let job = LaunchJob(label: "com.x.anything", programs: ["/Applications/Foo.app/Contents/MacOS/Foo"])
        let matches = Fixtures.match(
            short,
            [
                Fixtures.user(.caches): [Self.entry("com.x"), Self.entry("com.x.other"), Self.entry("com.xylophone")],
                Fixtures.user(.preferences): [Self.entry("com.x.plist", directory: false)],
                Fixtures.user(.launchAgents): [LeftoverEntry(name: "com.x.anything.plist", isDirectory: false, launchJob: job)],
                Fixtures.user(.containers): [LeftoverEntry(name: "6F1B0C52-0000-4000-8000-0123456789AB", metadataIdentifier: "com.x.help")],
                Fixtures.user(.groupContainers): [Self.entry("group.com.x.shared")],
            ])
        #expect(Fixtures.names(matches) == ["com.x"])
    }

    @Test func extraRule1_aOnePartBundleIDMatchesOnlyItself() {
        let tiny = Fixtures.app("foo", name: "Foo", executable: "foo")
        let matches = Fixtures.match(
            tiny, [Fixtures.user(.caches): [Self.entry("foo"), Self.entry("foo.bar"), Self.entry("foobar")]])
        #expect(Fixtures.names(matches) == ["foo"])
    }

    @Test func extraRule1_shortBundleIDGroupContainerStillMatchesExactly() {
        let short = Fixtures.app("com.x", name: "X", executable: "x")
        let matches = Fixtures.match(short, [Fixtures.user(.groupContainers): [Self.entry("group.com.x")]])
        #expect(Fixtures.names(matches) == ["group.com.x"])
    }

    @Test func extraRule2_incident_pearcleaner506_nameSharedWithAnotherInstalledAppIsDropped() {
        // Firefox Nightly's executable is "firefox". The folder "Firefox" is the release app's profile.
        let nightly = Fixtures.app(
            "org.mozilla.nightly", name: "Firefox Nightly", executable: "firefox",
            path: "/Applications/Firefox Nightly.app")
        let release = Fixtures.other("org.mozilla.firefox", name: "Firefox", executable: "firefox")
        let listing = [Fixtures.user(.applicationSupport): [Self.entry("Firefox"), Self.entry("Firefox Nightly")]]

        let both = Fixtures.match(nightly, others: [release], listing)
        #expect(Fixtures.names(both) == ["Firefox Nightly"])

        // Without the release app installed, "firefox" (the executable) is only this app's.
        let alone = Fixtures.match(nightly, listing)
        #expect(Set(Fixtures.names(alone)) == ["Firefox", "Firefox Nightly"])
    }

    @Test(arguments: ["name", "display name", "executable", "last bundle ID part"])
    func extraRule2_everyKindOfSharedNameIsChecked(kind: String) {
        let target = Fixtures.app(name: "Shared", displayName: nil, executable: "shared")
        let sibling: AppFacts
        switch kind {
        case "name": sibling = Fixtures.other("com.a.One", name: "Shared", executable: "one")
        case "display name":
            var made = Fixtures.other("com.a.One", name: "One", executable: "one")
            made.displayName = "Shared"
            sibling = made
        case "executable": sibling = Fixtures.other("com.a.One", name: "One", executable: "SHARED")
        default: sibling = Fixtures.other("com.a.Shared", name: "One", executable: "one")
        }
        let matches = Fixtures.match(
            target, others: [sibling], [Fixtures.user(.applicationSupport): [Self.entry("Shared")]])
        #expect(matches.candidates.isEmpty)
    }

    @Test func extraRule2_incompleteInventoryOffersNoNameOnlyMatches() {
        let matches = Fixtures.match(
            Fixtures.app(), complete: false,
            [
                Fixtures.user(.applicationSupport): [Self.entry("Foo Tool")],
                Fixtures.user(.caches): [Self.entry("com.example.Foo")],
            ])
        // The bundle-ID match stays: it needs no inventory. The name-only match goes.
        #expect(Fixtures.names(matches) == ["com.example.Foo"])
        #expect(matches.notice != nil)
    }

    @Test func extraRule3_folderHoldingAnotherAppsBundleIDIsDropped() {
        let other = Fixtures.other("com.other.Bar", name: "Bar")
        let matches = Fixtures.match(
            Fixtures.app(), others: [other],
            [Fixtures.user(.applicationSupport): [Self.entry("com.example.Foo"), Self.entry("Foo Tool")]],
            children: { _, name in name == "Foo Tool" ? ["settings.json", "com.OTHER.bar.helper"] : ["data"] })
        #expect(Fixtures.names(matches) == ["com.example.Foo"])
    }

    @Test func extraRule3_ownBundleIDInsideAChildNameIsNotAnotherApp() {
        let canary = Fixtures.other("com.example.Foo.canary", name: "Foo Canary")
        let matches = Fixtures.match(
            Fixtures.app(), others: [canary],
            [Fixtures.user(.applicationSupport): [Self.entry("com.example.Foo")]],
            children: { _, _ in ["com.example.Foo.helper", "com.example.Foo.cache"] })
        #expect(Fixtures.names(matches) == ["com.example.Foo"])
    }

    @Test func extraRule3_folderThatCannotBeListedKeepsOnlyBundleIDEvidence() {
        let matches = Fixtures.match(
            Fixtures.app(),
            [Fixtures.user(.applicationSupport): [Self.entry("com.example.Foo"), Self.entry("Foo Tool")]],
            children: { _, _ in nil })
        #expect(Fixtures.names(matches) == ["com.example.Foo"])
    }

    @Test func extraRule3_filesAreNotListed() {
        var asked = 0
        let matches = Fixtures.match(
            Fixtures.app(),
            [Fixtures.user(.preferences): [Self.entry("com.example.Foo.plist", directory: false)]],
            children: { _, _ in
                asked += 1
                return nil
            })
        #expect(Fixtures.names(matches) == ["com.example.Foo.plist"])
        #expect(asked == 0)
    }

    @Test func idThatExtendsThisAppsIDBelongsToTheOtherApp() {
        // Chrome is `com.google.Chrome`; Canary is `com.google.Chrome.canary`.
        let chrome = Fixtures.app("com.google.Chrome", name: "Chrome", executable: "Chrome", path: "/Applications/Chrome.app")
        let canary = Fixtures.other("com.google.Chrome.canary", name: "Chrome Canary")
        let matches = Fixtures.match(
            chrome, others: [canary],
            [
                Fixtures.user(.caches): [Self.entry("com.google.Chrome"), Self.entry("com.google.Chrome.canary")],
                Fixtures.user(.preferences): [
                    Self.entry("com.google.Chrome.plist", directory: false),
                    Self.entry("com.google.Chrome.canary.plist", directory: false),
                    Self.entry("com.google.Chrome.helper.plist", directory: false),
                ],
                Fixtures.user(.containers): [LeftoverEntry(name: "6F1B0C52-0000-4000-8000-0123456789AB", metadataIdentifier: "com.google.Chrome.canary.xpc")],
                Fixtures.user(.launchAgents): [
                    LeftoverEntry(
                        name: "canary.plist", isDirectory: false,
                        launchJob: LaunchJob(label: "com.google.Chrome.canary.update", programs: ["/Applications/Chrome.app/Contents/MacOS/x"]))
                ],
            ])
        #expect(Set(Fixtures.names(matches)) == [
            "com.google.Chrome", "com.google.Chrome.plist", "com.google.Chrome.helper.plist",
        ])
    }

    @Test func incident_pearcleaner571_aPrefixOfTheNameNeverMatches() {
        let chrome = Fixtures.app("com.google.Chrome", name: "Chrome", executable: "Chrome")
        let matches = Fixtures.match(
            chrome,
            [Fixtures.user(.applicationSupport): [
                Self.entry("chro"), Self.entry("Chrom"), Self.entry("Chromium"), Self.entry("Chrome Helper"),
                Self.entry("ChromeSetup"), Self.entry("Chrome2"), Self.entry("Google Chrome"),
            ]])
        #expect(matches.candidates.isEmpty)

        // The other direction: an app called "chro" matches the folder "chro" and not "Chrome".
        let short = Fixtures.app("com.example.chro", name: "chro", executable: "chro")
        let shortMatches = Fixtures.match(short, [Fixtures.user(.applicationSupport): [Self.entry("Chrome"), Self.entry("chro")]])
        #expect(Fixtures.names(shortMatches) == ["chro"])
        // And a long name never matches a longer folder that merely starts with it.
        let chromium = Fixtures.app("com.example.Chromium", name: "Chromium", executable: "Chromium")
        #expect(Fixtures.match(chromium, [Fixtures.user(.applicationSupport): [Self.entry("Chromium Embedded"), Self.entry("Chrom")]]).candidates.isEmpty)
    }

    @Test func nothingMatchesBySubstringOrPartialBundleID() {
        let matches = Fixtures.match(
            Fixtures.app(),
            [Fixtures.user(.caches): [
                Self.entry("com.example.Foobar"), Self.entry("com.example.Fo"), Self.entry("xcom.example.Foo"),
                Self.entry("com.example.FooBar.plist"), Self.entry("Foo.com.example"), Self.entry("com.example"),
            ]])
        #expect(matches.candidates.isEmpty)
    }

    @Test func comparisonIgnoresCase() {
        let matches = Fixtures.match(
            Fixtures.app(),
            [Fixtures.user(.caches): [Self.entry("COM.EXAMPLE.FOO")], Fixtures.user(.applicationSupport): [Self.entry("fOO tOOL"), Self.entry("fOO tOOL ")]])
        #expect(Fixtures.names(matches) == ["fOO tOOL", "COM.EXAMPLE.FOO"])
    }

    @Test func aDotAppIsNeverALeftover() {
        let matches = Fixtures.match(
            Fixtures.app(),
            [Fixtures.user(.applicationSupport): [Self.entry("com.example.Foo.app"), Self.entry("com.example.Foo.Helper.APP")]])
        #expect(matches.candidates.isEmpty)
    }

    @Test func anotherCopyWithTheSameBundleIDMeansNothingIsOffered() {
        let copy = Fixtures.app("com.example.Foo", path: "/Users/test/Applications/Foo.app")
        let matches = Fixtures.match(
            Fixtures.app(), others: [copy], [Fixtures.user(.caches): [Self.entry("com.example.Foo")]])
        #expect(matches.candidates.isEmpty)
        #expect(matches.notice != nil)
    }

    @Test func anAppWithoutABundleIDMatchesNothing() {
        let matches = Fixtures.match(
            Fixtures.app(nil), [Fixtures.user(.applicationSupport): [Self.entry("Foo")]])
        #expect(matches.candidates.isEmpty)
        #expect(matches.notice != nil)
    }

    @Test func libraryMatchesAreInfoAndTheirFoldersAreNotListed() {
        var asked = 0
        let matches = Fixtures.match(
            Fixtures.app(),
            [
                Fixtures.system(.applicationSupport): [Self.entry("com.example.Foo"), Self.entry("Foo Tool")],
                Fixtures.system(.privilegedHelperTools): [Self.entry("com.example.Foo.helper", directory: false)],
                Fixtures.system(.launchDaemons): [
                    LeftoverEntry(
                        name: "d.plist", isDirectory: false,
                        launchJob: LaunchJob(label: "com.example.Foo.helper", programs: ["/Library/PrivilegedHelperTools/com.example.Foo.helper"]))
                ],
            ],
            children: { _, _ in
                asked += 1
                return []
            })
        #expect(matches.candidates.count == 4)
        #expect(matches.candidates.allSatisfy { $0.tier == .info && $0.place.scope == .system })
        #expect(asked == 0)
    }

    @Test func candidatesComeInFolderOrderThenByName() {
        let matches = Fixtures.match(
            Fixtures.app(),
            [
                Fixtures.user(.preferences): [Self.entry("com.example.Foo.b.plist", directory: false), Self.entry("com.example.Foo.a.plist", directory: false)],
                Fixtures.user(.applicationSupport): [Self.entry("com.example.Foo")],
            ])
        #expect(Fixtures.names(matches) == ["com.example.Foo", "com.example.Foo.a.plist", "com.example.Foo.b.plist"])
    }

    // MARK: Where leftovers are searched (§2)

    @Test func searchedFoldersAreExactlyTheSpecifiedOnes() {
        let user = LeftoverPlace.all.filter { $0.scope == .user }.map { $0.folder.components.joined(separator: "/") }
        #expect(user == [
            "Application Support", "Caches", "Containers", "Group Containers", "Preferences",
            "Preferences/ByHost", "Saved Application State", "HTTPStorages", "WebKit", "Logs",
            "LaunchAgents", "Application Scripts", "Cookies",
        ])
        let system = LeftoverPlace.all.filter { $0.scope == .system }.map { $0.folder.components.joined(separator: "/") }
        #expect(system.suffix(2) == ["LaunchDaemons", "PrivilegedHelperTools"])
    }

    @Test func noSearchedFolderIsPersonalOrSyncedData() {
        let forbidden: Set<String> = [
            "Documents", "Desktop", "Downloads", "Mobile Documents", "CloudStorage", "Pictures", "Mail", "Messages",
        ]
        for place in LeftoverPlace.all {
            #expect(place.folder.components.allSatisfy { !forbidden.contains($0) && !$0.hasPrefix(".") })
        }
    }
}
