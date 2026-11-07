import Foundation
import Testing
@testable import CleanerCore

/// One row of `RULE_CATALOG.md` §3 with a path it must protect and a neighbour it must not.
struct ProtectedCase: Sendable, CustomTestStringConvertible {
    let pattern: String
    let reason: ProtectedReason
    let hit: String
    let miss: String
    var testDescription: String { pattern }

    init(_ pattern: String, _ reason: ProtectedReason, hit: String, miss: String) {
        self.pattern = pattern
        self.reason = reason
        self.hit = hit
        self.miss = miss
    }
}

enum ProtectedCases {
    static let all: [ProtectedCase] = system + roots + sync + apple + fragile + agents + stores + vendors + secrets

    static let system: [ProtectedCase] = [
        .init("/System/**", .system, hit: "/System/Library/CoreServices/x", miss: "/Systemic/x"),
        .init("/usr/**", .system, hit: "/usr/local/bin/x", miss: "/usrx/bin"),
        .init("/opt/**", .system, hit: "/opt/homebrew/Caskroom/x", miss: "/optional/x"),
        .init("/bin/**", .system, hit: "/bin/ls", miss: "/binary/x"),
        .init("/sbin/**", .system, hit: "/sbin/mount", miss: "/sbinx/x"),
        .init("/etc/**", .system, hit: "/etc/hosts", miss: "/etcetera/x"),
        .init("/private/etc/**", .system, hit: "/private/etc/hosts", miss: "/private/etcx/y"),
        .init("/private/var/db/**", .system, hit: "/private/var/db/diagnostics/x",
              miss: "/private/var/folders/ab/cd/C/x"),
        .init("/private/var/vm/**", .system, hit: "/private/var/vm/swapfile0", miss: "/private/var/vmx/a"),
        .init("/Library/Updates/**", .system, hit: "/Library/Updates/x",
              miss: "/Library/Caches/com.example.app"),
        .init("/macOS Install Data/**", .system, hit: "/macOS Install Data/x", miss: "/macOS Install Data 2/x"),
        .init("/System/Volumes/Preboot/**", .system, hit: "/System/Volumes/Preboot/x", miss: "/Volumes/Backup/x"),
        .init("/Library/Apple/**", .system, hit: "/Library/Apple/usr/x",
              miss: "/Library/Application Support/Example/x"),
        .init("/Library/Keychains/**", .system, hit: "/Library/Keychains/System.keychain",
              miss: "/Library/KeychainsX/a"),
        .init("/Library/Extensions/**", .system, hit: "/Library/Extensions/x.kext",
              miss: "/Library/Extensionsx/a"),
        .init("/Library/SystemExtensions/**", .system, hit: "/Library/SystemExtensions/u/x",
              miss: "/Library/SystemExtensionsX/a"),
    ]

    static let roots: [ProtectedCase] = [
        .init("/", .root, hit: "/", miss: "/Volumes/Backup"),
        .init("/Applications", .root, hit: "/Applications", miss: "/Applications/Install macOS Sonoma.app"),
        .init("/Library", .root, hit: "/Library", miss: "/Library/Caches/com.example.app"),
        .init("/Users", .root, hit: "/Users", miss: "/Users/other/file.txt"),
        .init("/Users/Shared", .root, hit: "/Users/Shared", miss: "/Users/Shared/Example/x"),
        .init("~", .root, hit: "~", miss: "~/Documents/x"),
        .init("~/Library", .root, hit: "~/Library", miss: "~/Library/Caches/com.example.app"),
    ]

    static let sync: [ProtectedCase] = [
        .init("~/Library/Mobile Documents/**", .syncAndIdentity,
              hit: "~/Library/Mobile Documents/com~apple~CloudDocs/x", miss: "~/Library/Mobile Documents Backup/x"),
        .init("~/Library/CloudStorage/**", .syncAndIdentity,
              hit: "~/Library/CloudStorage/Dropbox/x", miss: "~/Library/CloudStorageX/x"),
        .init("~/Library/Caches/CloudKit/**", .syncAndIdentity,
              hit: "~/Library/Caches/CloudKit/x", miss: "~/Library/Caches/com.example.app"),
        .init("~/Library/Caches/com.apple.bird/**", .syncAndIdentity,
              hit: "~/Library/Caches/com.apple.bird/x", miss: "~/Library/Caches/com.apple.birdy/x"),
        .init("~/Library/Caches/com.apple.cloudd/**", .syncAndIdentity,
              hit: "~/Library/Caches/com.apple.cloudd/x", miss: "~/Library/Caches/com.apple.cloudd2/x"),
        .init("~/Library/Caches/FileProvider/**", .syncAndIdentity,
              hit: "~/Library/Caches/FileProvider/x", miss: "~/Library/Caches/FileProviderX/x"),
        .init("~/Library/Application Support/FileProvider/**", .syncAndIdentity,
              hit: "~/Library/Application Support/FileProvider/x", miss: "~/Library/Application Support/Example/x"),
        .init("~/Library/Keychains/**", .syncAndIdentity,
              hit: "~/Library/Keychains/login.keychain-db", miss: "~/Library/KeychainsX/a"),
        .init("~/Library/Accounts/**", .syncAndIdentity,
              hit: "~/Library/Accounts/Accounts4.sqlite", miss: "~/Library/AccountsX/a"),
    ]

    static let apple: [ProtectedCase] = [
        .init("~/Library/Mail/**", .appleData, hit: "~/Library/Mail/V10/x", miss: "~/Library/Mail Downloads/x"),
        .init("~/Library/Messages/**", .appleData,
              hit: "~/Library/Messages/Attachments/ab/x", miss: "~/Library/Messages/Caches/Previews/x"),
        .init("~/Library/Calendars/**", .appleData, hit: "~/Library/Calendars/x", miss: "~/Library/CalendarsX/x"),
        .init("~/Library/Contacts/**", .appleData, hit: "~/Library/Contacts/x", miss: "~/Library/ContactsX/x"),
        .init("~/Pictures/*.photoslibrary/**", .appleData,
              hit: "~/Pictures/Photos Library.photoslibrary/originals/x", miss: "~/Pictures/Screenshots/x.png"),
        .init("~/Library/Safari/**", .appleData,
              hit: "~/Library/Safari/History.db", miss: "~/Library/Caches/com.apple.Safari/x"),
        .init("~/Library/Containers/com.apple.Notes/**", .appleData,
              hit: "~/Library/Containers/com.apple.Notes/Data/x",
              miss: "~/Library/Containers/com.example.app/Data/Library/Caches/x"),
    ]

    static let fragile: [ProtectedCase] = [
        .init("~/Library/Caches/com.apple.FontRegistry*/**", .fragileAppleCache,
              hit: "~/Library/Caches/com.apple.FontRegistry.501/x", miss: "~/Library/Caches/com.apple.Font/x"),
        .init("~/Library/Caches/com.apple.Spotlight*/**", .fragileAppleCache,
              hit: "~/Library/Caches/com.apple.Spotlight/x", miss: "~/Library/Caches/com.apple.Spot/x"),
        .init("~/Library/Caches/com.apple.finder/**", .fragileAppleCache,
              hit: "~/Library/Caches/com.apple.finder/x", miss: "~/Library/Caches/com.apple.finderx/x"),
        .init("**/*com.apple.coreaudio*/**", .fragileAppleCache,
              hit: "~/Library/Caches/com.apple.coreaudio.cache/x", miss: "~/Library/Caches/com.apple.coreaudi/x"),
        .init("~/Library/Application Support/com.apple.idleassetsd/**", .fragileAppleCache,
              hit: "~/Library/Application Support/com.apple.idleassetsd/x",
              miss: "~/Library/Application Support/com.apple.idleassets/x"),
        .init("~/Library/Application Support/com.apple.wallpaper/**", .fragileAppleCache,
              hit: "~/Library/Application Support/com.apple.wallpaper/x",
              miss: "~/Library/Application Support/com.apple.wallpaperx/x"),
        .init("**/com.apple.homed/**", .fragileAppleCache,
              hit: "~/Library/Caches/com.apple.homed/x", miss: "~/Library/Caches/com.apple.homedx/x"),
        .init("**/HomeKit/**", .fragileAppleCache, hit: "~/Library/HomeKit/x", miss: "~/Library/HomeKitX/x"),
        .init("**/FamilyCircle/**", .fragileAppleCache,
              hit: "~/Library/FamilyCircle/x", miss: "~/Library/FamilyCircles/x"),
        .init("**/com.apple.containermanagerd/**", .fragileAppleCache,
              hit: "~/Library/Caches/com.apple.containermanagerd/x",
              miss: "~/Library/Caches/com.apple.containermanagerdx/x"),
    ]

    static let agents: [ProtectedCase] = [
        .init("~/.claude/**", .agentState, hit: "~/.claude/projects/a/memory/x", miss: "~/.claude/cache/x"),
        .init("~/.claude/**/worktrees/**", .agentState,
              hit: "~/.claude/cache/worktrees/a/x", miss: "~/.claude/shell-snapshots/x"),
        .init("~/.codex/**", .agentState, hit: "~/.codex/sessions/x", miss: "~/.codex/.tmp/x"),
        .init("~/.codex/**/worktrees/**", .agentState, hit: "~/.codex/.tmp/worktrees/a", miss: "~/.codex/cache/x"),
        .init("~/.kiro/**", .agentState, hit: "~/.kiro/steering/x", miss: "~/.kirox/x"),
        .init("~/.cursor/**", .agentState, hit: "~/.cursor/extensions/x", miss: "~/.cursors/x"),
        .init("~/.ollama/models/**", .agentState, hit: "~/.ollama/models/blobs/x", miss: "~/.ollama/logs/x"),
        .init("~/.lmstudio/models/**", .agentState, hit: "~/.lmstudio/models/x", miss: "~/.lmstudio/cache/x"),
        .init("~/.cache/huggingface/**", .agentState, hit: "~/.cache/huggingface/hub/x", miss: "~/.cache/pip/x"),
    ]

    static let stores: [ProtectedCase] = [
        .init("**/pypoetry/virtualenvs/**", .liveStore,
              hit: "~/Library/Caches/pypoetry/virtualenvs/proj-py3.12/bin/python",
              miss: "~/Library/Caches/pypoetry/cache/x"),
        .init("**/pnpm/dlx/**", .liveStore,
              hit: "~/Library/Caches/pnpm/dlx/abc/x", miss: "~/Library/Caches/pnpm/metadata/x"),
        .init("**/renv/**", .liveStore,
              hit: "~/Library/Caches/org.R-project.R/renv/x", miss: "~/Library/Caches/org.R-project.R/x"),
        .init("**/llama.cpp/**", .liveStore, hit: "~/Library/Caches/llama.cpp/x", miss: "~/Library/Caches/llama/x"),
        .init("**/ms-playwright/**", .liveStore,
              hit: "~/Library/Caches/ms-playwright/chromium-1/x", miss: "~/Library/Caches/ms-playwrightx/x"),
        .init("~/.yarn/berry/cache/**", .liveStore,
              hit: "~/.yarn/berry/cache/x.zip", miss: "~/.yarn/berry/index/x"),
        .init("~/.cargo/registry/src/**", .liveStore,
              hit: "~/.cargo/registry/src/index/x", miss: "~/.cargo/registry/cache/index/x.crate"),
        .init("~/.cargo/registry/index/**", .liveStore,
              hit: "~/.cargo/registry/index/x", miss: "~/.cargo/registry/cache/x"),
        .init("~/.cargo/git/**", .liveStore, hit: "~/.cargo/git/db/x", miss: "~/.cargo/bin/x"),
    ]

    static let vendors: [ProtectedCase] = [
        .init("**/*izotope*/**", .licensedVendor,
              hit: "~/Library/Application Support/iZotope/x", miss: "~/Library/Application Support/Zotero/x"),
        .init("**/Native Instruments/**", .licensedVendor,
              hit: "~/Library/Application Support/Native Instruments/x",
              miss: "~/Library/Application Support/Native Plugins/x"),
        .init("**/com.native-instruments.*/**", .licensedVendor,
              hit: "~/Library/Caches/com.native-instruments.Kontakt/x", miss: "~/Library/Caches/com.native.Thing/x"),
        .init("**/Avid/**", .licensedVendor,
              hit: "~/Library/Application Support/Avid/x", miss: "~/Library/Application Support/Avidemux/x"),
        .init("**/com.avid.*/**", .licensedVendor,
              hit: "~/Library/Caches/com.avid.ProTools/x", miss: "~/Library/Caches/com.avidly.Thing/x"),
        .init("**/*fabfilter*/**", .licensedVendor,
              hit: "~/Library/Application Support/FabFilter/x", miss: "~/Library/Application Support/Fab/x"),
        .init("**/PACE/**", .licensedVendor,
              hit: "~/Library/Application Support/PACE/x", miss: "~/Library/Application Support/PACER/x"),
        .init("**/PACE Anti-Piracy/**", .licensedVendor,
              hit: "/Library/Application Support/PACE Anti-Piracy/x",
              miss: "/Library/Application Support/PACE Anti/x"),
        .init("**/*ilok*/**", .licensedVendor,
              hit: "~/Library/Caches/com.ilok.License-Support/x", miss: "~/Library/Caches/com.example.lock/x"),
        .init("**/Library/Caches/Adobe*/**", .licensedVendor,
              hit: "~/Library/Caches/Adobe Camera Raw/x",
              miss: "~/Library/Application Support/Adobe/Common/Media Cache Files/x"),
        .init("**/*crowdstrike*/**", .licensedVendor,
              hit: "/Library/Application Support/CrowdStrike/x", miss: "/Library/Application Support/Crowd/x"),
        .init("**/*sentinelone*/**", .licensedVendor,
              hit: "/Library/Application Support/SentinelOne/x", miss: "/Library/Application Support/Sentinel/x"),
        .init("**/*intego*/**", .licensedVendor, hit: "/Library/Intego/x", miss: "/Library/Integral/x"),
        .init("**/*symantec*/**", .licensedVendor,
              hit: "/Library/Application Support/Symantec/x", miss: "/Library/Application Support/Symphony/x"),
        .init("**/*jamf*/**", .licensedVendor,
              hit: "/Library/Application Support/JAMF/x", miss: "/Library/Application Support/Jam/x"),
    ]

    static let secrets: [ProtectedCase] = [
        .init("**/*1password*/**", .passwordManager,
              hit: "~/Library/Group Containers/2BUA8C4S2C.com.1password/x",
              miss: "~/Library/Group Containers/group.com.example/x"),
        .init("**/*bitwarden*/**", .passwordManager,
              hit: "~/Library/Application Support/Bitwarden/x", miss: "~/Library/Application Support/Bit/x"),
        .init("**/*keepassxc*/**", .passwordManager,
              hit: "~/Library/Application Support/KeePassXC/x", miss: "~/Library/Application Support/KeePass/x"),
        .init("**/*dashlane*/**", .passwordManager,
              hit: "~/Library/Application Support/Dashlane/x", miss: "~/Library/Application Support/Dash/x"),
        .init("**/*ledger live*/**", .passwordManager,
              hit: "~/Library/Application Support/Ledger Live/x", miss: "~/Library/Application Support/Ledger/x"),
        .init("**/*ledger-live*/**", .passwordManager,
              hit: "~/Library/Caches/ledger-live-desktop/x", miss: "~/Library/Caches/ledger-desktop/x"),
        .init("**/*exodus*/**", .passwordManager,
              hit: "~/Library/Application Support/Exodus/x", miss: "~/Library/Application Support/Exo/x"),
        .init("**/*wasabi*/**", .passwordManager, hit: "~/.walletwasabi/x", miss: "~/.wallet/x"),
    ]
}

struct PathPolicyTests {
    // MARK: - Protected list

    @Test("Every protected row has a test case", arguments: [ProtectedCases.all])
    func casesCoverEveryRow(cases: [ProtectedCase]) {
        let rows = ProtectedList.entries.map(\.pattern)
        #expect(Set(cases.map(\.pattern)) == Set(rows))
        #expect(cases.count == rows.count)
        #expect(Set(rows).count == rows.count, "pattern appears twice")
    }

    @Test("Case reasons match the list", arguments: ProtectedCases.all)
    func reasonsMatchList(testCase: ProtectedCase) throws {
        let entry = try #require(ProtectedList.entries.first { $0.pattern == testCase.pattern })
        #expect(entry.reason == testCase.reason)
    }

    @Test("Protected path is protected", arguments: ProtectedCases.all)
    func hitIsProtected(testCase: ProtectedCase) {
        let reason = TestEnv.policy().protectedReason(for: TestEnv.url(testCase.hit))
        #expect(reason == testCase.reason)
    }

    @Test("Neighbouring path is not protected", arguments: ProtectedCases.all)
    func missIsNotProtected(testCase: ProtectedCase) {
        let reason = TestEnv.policy().protectedReason(for: TestEnv.url(testCase.miss))
        #expect(reason == nil)
    }

    @Test func exceptionsOnlyOnSubtreePatterns() {
        for entry in ProtectedList.entries where !entry.exceptions.isEmpty {
            #expect(entry.pattern.hasSuffix("/**"), "\(entry.pattern) has exceptions but is not a subtree")
        }
    }

    @Test("Agent folders: caches are free, memory is not", arguments: [
        ("~/.claude/cache/x", false),
        ("~/.claude/paste-cache/x", false),
        ("~/.claude/shell-snapshots/x", false),
        ("~/.claude/projects/a/memory/x", true),
        ("~/.claude/projects", true),
        ("~/.claude", true),
        ("~/.claude/cache/worktrees/a", true),
        ("~/.codex/cache/x", false),
        ("~/.codex/.tmp/x", false),
        ("~/.codex/config.toml", true),
    ])
    func agentFolders(path: String, isProtected: Bool) {
        #expect((TestEnv.policy().protectedReason(for: TestEnv.url(path)) != nil) == isProtected)
    }

    @Test func messagesPreviewsAreTheOnlyMessagesExemption() {
        let policy = TestEnv.policy()
        #expect(policy.protectedReason(for: TestEnv.url("~/Library/Messages/Caches/Previews")) == nil)
        #expect(policy.protectedReason(for: TestEnv.url("~/Library/Messages/StickerCache/a")) == nil)
        #expect(policy.protectedReason(for: TestEnv.url("~/Library/Messages/Caches")) == .appleData)
        #expect(policy.protectedReason(for: TestEnv.url("~/Library/Messages/chat.db")) == .appleData)
    }

    @Test func protectedListIgnoresCase() {
        let policy = TestEnv.policy()
        #expect(policy.protectedReason(for: TestEnv.url("~/library/MAIL/V10/x")) == .appleData)
        #expect(policy.protectedReason(for: TestEnv.url("~/LIBRARY")) == .root)
    }

    @Test func dataVolumePrefixIsReadAsFirmlinkedTwin() {
        let policy = TestEnv.policy()
        #expect(policy.protectedReason(for: TestEnv.url("/System/Volumes/Data/Users/tester/Library/Mail/x")) == .appleData)
        #expect(policy.protectedReason(for: TestEnv.url("/System/Volumes/Data/System/Library/x")) == .system)
        #expect(policy.protectedReason(for: TestEnv.url("/System/Volumes/Data")) == .root)
        #expect(policy.protectedReason(for: TestEnv.url("/System/Volumes/Data/Users/tester/Library/Caches/com.example.app")) == nil)
    }

    @Test func dotDotIsResolvedBeforeMatching() {
        let policy = TestEnv.policy()
        #expect(policy.protectedReason(for: TestEnv.url("~/Library/Caches/../Mail/x")) == .appleData)
        #expect(policy.protectedReason(for: TestEnv.url("/private/var/folders/../db/x")) == .system)
    }

    @Test func nonFileOrRelativeURLsAreProtected() throws {
        let policy = TestEnv.policy()
        #expect(policy.protectedReason(for: try #require(URL(string: "https://example.com/a"))) != nil)
        #expect(policy.protectedReason(for: try #require(URL(string: "relative/path"))) != nil)
    }

    // MARK: - User exclusions

    @Test func userExclusionWins() {
        let excluded = TestEnv.url("~/Library/Caches/com.example.app")
        let policy = TestEnv.policy(exclusions: [excluded])
        #expect(policy.protectedReason(for: excluded) == .userExcluded)
        #expect(policy.protectedReason(for: excluded.appending(path: "deep/file")) == .userExcluded)
        #expect(policy.protectedReason(for: TestEnv.url("~/Library/Caches/com.example.app2")) == nil)
        #expect(policy.protectedReason(for: TestEnv.url("~/Library/Caches/com.example")) == nil)
        #expect(TestEnv.policy().protectedReason(for: excluded) == nil)
    }

    @Test func folderContainingAnExclusionIsProtected() {
        let policy = TestEnv.policy(exclusions: [TestEnv.url("~/Library/Application Support/Example/keep")])
        #expect(policy.protectedReason(for: TestEnv.url("~/Library/Application Support/Example")) == .userExcluded)
        #expect(policy.protectedReason(for: TestEnv.url("~/Library/Application Support/Other")) == nil)
    }

    @Test func exclusionIgnoresCaseAndTrailingSlash() {
        let policy = TestEnv.policy(exclusions: [URL(filePath: "/Users/tester/Library/Caches/Keep/", directoryHint: .isDirectory)])
        #expect(policy.protectedReason(for: TestEnv.url("~/library/caches/keep/x")) == .userExcluded)
    }

    // MARK: - isInside

    @Test("isInside", arguments: [
        ("/a/b/c", "/a/b", true),
        ("/a/b", "/a/b", true),
        ("/a/b/", "/a/b", true),
        ("/a/b/c", "/a/b/", true),
        ("/a/bc", "/a/b", false),
        ("/a/b/../bc", "/a/b", false),
        ("/a/b/c/../../x", "/a/b", false),
        ("/a/b/./c", "/a/b", true),
        ("/a", "/a/b", false),
        ("/a/B/c", "/a/b", false),
        ("/a/b/c", "/", true),
    ])
    func isInside(path: String, root: String, expected: Bool) {
        #expect(TestEnv.policy().isInside(URL(filePath: path), roots: [URL(filePath: root)]) == expected)
    }

    @Test func isInsideChecksEveryRoot() {
        let roots = [URL(filePath: "/x/one"), URL(filePath: "/x/two")]
        #expect(TestEnv.policy().isInside(URL(filePath: "/x/two/a"), roots: roots))
        #expect(!TestEnv.policy().isInside(URL(filePath: "/x/three/a"), roots: roots))
        #expect(!TestEnv.policy().isInside(URL(filePath: "/x/one/a"), roots: []))
    }

    // MARK: - isRoot

    @Test("isRoot", arguments: [
        ("/", true),
        ("/Applications", true),
        ("/Applications/", true),
        ("/Library", true),
        ("/Users", true),
        ("/Users/Shared", true),
        ("/Users/tester", true),
        ("/Users/tester/", true),
        ("/Users/tester/Library", true),
        ("/Users/tester/library", true),
        ("/Users/tester/Library/Caches/..", true),
        ("/System/Volumes/Data/Users/tester", true),
        ("/Users/tester/Library/Caches", false),
        ("/Users/tester/Library/Caches/com.example.app", false),
        ("/Users/other", false),
        ("/Applications/Install macOS Sonoma.app", false),
        ("/Library/Caches", false),
    ])
    func wellKnownRoots(path: String, expected: Bool) {
        #expect(TestEnv.policy().isRoot(URL(filePath: path), roots: []) == expected)
    }

    @Test func ruleRootIsRootButItsChildIsNot() {
        let root = TestEnv.url("~/Library/Logs/DiagnosticReports")
        let policy = TestEnv.policy()
        #expect(policy.isRoot(root, roots: [root]))
        #expect(policy.isRoot(URL(filePath: root.path() + "/"), roots: [root]))
        #expect(!policy.isRoot(root.appending(path: "a.ips"), roots: [root]))
        #expect(!policy.isRoot(TestEnv.url("~/Library/Logs/DiagnosticReportsX"), roots: [root]))
    }

    @Test func unusableURLCountsAsRoot() throws {
        #expect(TestEnv.policy().isRoot(try #require(URL(string: "relative")), roots: []))
    }

    // MARK: - Incidents (docs/RESEARCH.md §3.3)

    @Test("Mole #823: ~/.claude/projects/*/memory is protected")
    func mole823AgentMemoryIsProtected() {
        let policy = TestEnv.policy()
        #expect(policy.protectedReason(for: TestEnv.url("~/.claude/projects/my-app/memory")) == .agentState)
        #expect(policy.protectedReason(for: TestEnv.url("~/.claude/projects/my-app/memory/notes.md")) == .agentState)
    }

    @Test("Mole #1689: the DiagnosticReports folder itself is a root")
    func mole1689RootFolderIsNeverDeleted() {
        let root = TestEnv.url("~/Library/Logs/DiagnosticReports")
        #expect(TestEnv.policy().isRoot(root, roots: [root]))
    }
}
