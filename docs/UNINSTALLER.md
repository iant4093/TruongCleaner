# App Uninstaller spec (Wave 6)

Written 2026-11-09 by the orchestrator from `docs/research/B-native-cleaner-apps.md`
(Pearcleaner, Lemon) and `docs/RESEARCH.md` §3.3. Our own design; no code copied.

Goal: remove an app and the files it left in the user's Library, without ever
touching another app's data. When in doubt, a file is not offered, or is offered
unchecked as Review.

## 1. Which apps can be uninstalled

| Refused | Why |
|---|---|
| Anything under `/System` | Sealed system volume |
| Bundle ID starting with `com.apple.` or signed by Apple (team ID absent and Apple anchor) | Pearcleaner #618 matched all of `com.apple` |
| TruongCleaner itself | — |
| App that is running (`NSRunningApplication` by bundle ID; unknown → refuse) | Mole #1854 |
| App with no `CFBundleIdentifier` | No evidence to match on |
| App not inside `/Applications` or `~/Applications` (depth ≤ 2) | Keep scope small |

App facts come from `Info.plist` (`CFBundleIdentifier`, `CFBundleName`,
`CFBundleDisplayName`, `CFBundleExecutable`, version) and the code signature via
Security (`SecStaticCodeCreateWithPath` + `SecCodeCopySigningInformation` →
team ID, Apple anchor). No `Process`.

## 2. Where leftovers are searched (direct children only)

`~/Library/` + `Application Support`, `Caches`, `Containers`, `Group Containers`,
`Preferences`, `Preferences/ByHost`, `Saved Application State`, `HTTPStorages`,
`WebKit`, `Logs`, `LaunchAgents`, `Application Scripts`, `Cookies`.

Shown as Info only (need admin, not deleted in v1): the same names under
`/Library/` plus `/Library/LaunchDaemons` and `/Library/PrivilegedHelperTools`.

**Never searched:** `~`, `~/Documents`, `~/Desktop`, `~/Downloads`, `~/.config`,
any dot-folder, `~/Library/Mobile Documents`, `~/Library/CloudStorage`
(Pearcleaner #587 deleted `~/Documents/OpenSCAD`). The global protected list
always applies.

## 3. Matching

Names are compared case-insensitively, whole name only. **No substring matching.**

| Evidence | Example | Tier |
|---|---|---|
| Name equals the bundle ID | `Caches/com.example.Foo` | Safe (pre-selected) |
| Name is bundle ID + `.` + suffix | `Preferences/com.example.Foo.plist`, `com.example.Foo.savedState`, `com.example.Foo.helper.plist`, `com.example.Foo.binarycookies` | Safe |
| Container whose `.com.apple.containermanagerd.metadata.plist` `MCMMetadataIdentifier` equals the bundle ID or starts with bundle ID + `.` | UUID-named folders in `Containers` | Safe |
| Group container named `<teamID>.<something>` where team ID matches the app's, or `group.<bundleID>[.x]` | `Group Containers/ABCDE12345.com.example` | Review |
| LaunchAgent plist whose `Label` equals the bundle ID or starts with bundle ID + `.`, **and** whose `Program`/`ProgramArguments[0]` points inside the app bundle | `LaunchAgents/com.example.Foo.agent.plist` | Safe |
| Name equals the app's name, display name or executable name (≥ 4 characters) | `Application Support/Foo` | Review (unchecked) |

Extra rules:

1. Bundle IDs with fewer than 3 dot parts match only by exact equality (Lemon's
   2-letter bundle ID bug deleted every launch agent).
2. **Shared names.** Build the installed-app inventory first (`/Applications`,
   `~/Applications`, depth 2). If the inventory fails, offer no name-only
   matches. A name-only match is dropped if any other installed app has the same
   name, display name, executable or a bundle ID whose last component equals it
   (Pearcleaner #506: Firefox Nightly removed Firefox's profiles).
3. A folder that contains another installed app's bundle ID anywhere in its
   direct children's names is dropped.
4. Every candidate passes `SafetyGate` like any other finding.

## 4. Deleting

- One synthetic rule per uninstall: `apps.uninstall` (tier Review, action `.trash`,
  roots = the searched folders + the app's parent folder). Only this rule and
  `installers.macOS` may remove a whole `.app` (`allowsWholeBundle`).
- The app bundle and the checked leftovers go to the Trash through `Cleaner`; one
  history entry per uninstall; Put Back works as for any clean.
- An app in `/Applications` owned by root or another user: show "Needs an
  administrator" and stop (no privilege escalation in v1).
- LaunchAgents stay loaded until logout; say so in the result sheet.

## 5. Tests that must exist (fixture home + fixture `/Applications` root)

Each incident has a test with its name in the test name: Pearcleaner #587
(Documents never searched), #618 (Apple apps refused), #506 (shared name dropped),
#571 (prefix like `chro…` never matches `Chrome`), Lemon short bundle ID, Mole
#1854 (running app refused). Plus: containers by metadata plist; launch agent
needs both label and program evidence; inventory failure drops name-only matches.
