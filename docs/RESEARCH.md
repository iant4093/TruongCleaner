# TruongCleaner: Research summary

Date: 2026-11-06. Machine: macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift 6.4, Apple silicon.

This file is the short version. Full reports with every source link are in
`docs/research/`:

| File | Topic |
|---|---|
| `docs/research/A-cleanup-tools-targets.md` | What Mole, mac-cleanup-py, mac-cleanup-sh, mac-cleaner-cli, PureMac and MacSai clean; their safety rules and incidents; a merged target catalog |
| `docs/research/B-native-cleaner-apps.md` | How Pearcleaner, Lemon Cleaner, Clean Me, PureMac, MacSai, Purge and Peel are built; leftover matching; helpers; deletion; issues |
| `docs/research/D-system-data.md` | What "System Data" is, every big contributor, who may touch what, and how to reconcile with Apple's numbers |
| `docs/research/E-tech-stack.md` | Liquid Glass APIs, architecture, permissions, signing, Sparkle, GitHub runners, CodeQL |

A fifth report (disk analyzers and the fastest scanning method) was stopped
before it finished. Spike S1 in `docs/PLAN.md` replaces it with a measurement
on this Mac.

Facts in these files are paraphrased from the sources they cite. **No code
from any other project may be copied into TruongCleaner** (see the license
table below).

---

## 1. Tech stack

| Choice | Pick | Reason |
|---|---|---|
| Language | Swift 6.4, Swift 6 mode, strict concurrency, warnings as errors | Native, fast, race-checked |
| UI | SwiftUI on macOS 26+; AppKit only for icons, Trash, Reveal, open panels | Standard controls get Liquid Glass automatically |
| Liquid Glass | `NavigationSplitView` (glass sidebar), `Form` + `.formStyle(.grouped)`, `.buttonStyle(.glass)` / `.glassProminent`, `GlassEffectContainer`, `.glassEffect(.regular)`, `ToolbarSpacer`, `.backgroundExtensionEffect()` | All `macOS 26.0`. The 27 SDK adds no new SwiftUI glass API (checked in the SDK) |
| Charts | Swift Charts (`BarMark`, `SectorMark`) | System framework, no size cost |
| State | `@Observable @MainActor` view models held in `@State` | Xcode 27 makes `@State` a macro that creates observable objects lazily |
| Core | Local SwiftPM package with three targets | Headless tests on CI |
| Tests | Swift Testing (`@Test`, `#expect`, parameterized) | Ran on this Mac with `swift test`, no simulator |
| Size | A bare SwiftUI + Charts app is 140 KB on disk (measured) | Lightweight goal is easy if we add no frameworks |
| Distribution | Not sandboxed, outside the App Store, GitHub Releases | App Store rule 2.4.5 forbids what a cleaner needs |
| Signing | Ad-hoc now; Developer ID optional later | See §5 |
| CI | GitHub `xcode-27` image (macOS 27.0.1, Xcode 27.0/27.1/27.2 RC, arm64) | There is no `macos-27` label |
| SAST | CodeQL for workflows only | CodeQL does not support Swift 6.4 / Xcode 27 yet |

### 1.1 System Settings look

- No public API draws System Settings' colored icon tiles. Draw them: white SF
  Symbol on a gradient rounded rectangle (about 24 pt, 6 pt continuous radius),
  then tune against a screenshot.
- Use glass on controls and navigation only, never on content rows. A grouped
  `Form` already looks like System Settings.
- Use `Glass.regular` everywhere; `.clear` is for media backgrounds.
- macOS 27 adds a system-wide Liquid Glass slider (clear to tinted). Test both
  ends. Handle `accessibilityReduceTransparency` for any custom background.
- SF Symbols 8 symbols are new in 27; on a 26 floor, use SF Symbols 7 names or
  gate them.

---

## 2. What "System Data" really is

Apple defines System Data as everything the Storage pane cannot put in another
category, and says you cannot manage it. There is **no public API** for the
per-category numbers. Only volume-level numbers are public, so the app must
compute its own breakdown and show the remainder as "Unexplained".

| Contributor | Typical size | Who can act | Our tier |
|---|---|---|---|
| APFS local Time Machine snapshots | 0 to hundreds of GB | List: user. Delete: root (`tmutil`) | Info + command |
| Spotlight index (`.Spotlight-V100`) | GBs; bug reports up to 132 GB | Root (`mdutil -E`) | Info + command |
| `/private/var/folders/…/C` and `T` | 11 GB to 135 GB outliers | User for own folder | Review, aged, owner app closed |
| `~/Library/Caches` | ~14 GB on a test Mac | User | Safe with exclusions |
| Xcode DerivedData / DeviceSupport / simulators | 6 GB / several GB / 20 GB+ | User; `xcrun simctl` | Safe / Review |
| Simulator runtimes | ~8 GB each | User via `xcrun simctl runtime delete` | Review |
| Docker Desktop disk image | 30–80 GB | `docker` CLI; on macOS 27 another team's container needs FDA | Owner command |
| iOS device backups | Tens of GB per device | FDA | Review (may be the only copy) |
| Mail downloads | Up to GBs | FDA | Safe if unedited, Mail closed, > 30 days |
| Apple Intelligence / Siri / language assets (`AssetsV2`) | 14–30 GB on macOS 27 | SIP; nobody | Info + Settings link |
| Rosetta cache (`/private/var/db/oah`) | Small; outliers of 600–800 GB | SIP; nobody | Info |
| Swap, sleepimage | 0 to tens of GB | System | Info |
| Software Update staging, Cryptexes, Preboot | 9–15 GB+ | SIP; nobody | Info (deleting staged updates made a Mac unbootable) |
| Purgeable | Tens of GB | System decides | Info: `importantUsage − available` |

macOS 27 changes that hit a cleaner:

1. Other developer teams' containers and group containers are **denied by
   default, with no prompt**. Full Disk Access is the workaround.
2. A list of non-sandboxed apps' `Application Support` folders (Chrome, Brave,
   Edge, Firefox, Discord, wallets) is protected.
3. Apps can no longer read the TCC database, so the classic FDA probe is dead.
4. Apple announced (2026-10-02) more controls on Full Disk Access, no date.
5. One unverified report says macOS 27 folds purgeable space into System Data.
   Spike S4 checks it.

---

## 3. Competitors

| Tool | Kind | License | Notes |
|---|---|---|---|
| [Mole](https://github.com/tw93/Mole) | Shell CLI | GPL-3.0 | 74k stars. Largest rule set, best safety engineering, deletes permanently |
| [Pearcleaner](https://github.com/alienator88/Pearcleaner) | Swift app uninstaller | Apache-2.0 + Commons Clause | 15k stars. On hold. Leftover search; root helper runs any string as root |
| [Lemon Cleaner](https://github.com/Tencent/lemon-cleaner) | Obj-C full cleaner | GPL-3.0 / GPL-2.0 | Data-driven XML rules; root daemon accepts any client |
| [PureMac](https://github.com/momenbasel/PureMac) | SwiftUI cleaner | MIT | Allow-list of roots, iCloud denylist; code origin uncertain |
| [MacSai](https://github.com/iliyami/MacSai) | SwiftUI cleaner | BSD-3-Clause | Trash by default with restore history; Sparkle |
| [Purge](https://github.com/jithin-sabu/purge-app) | SwiftUI cleaner | MIT | Helper target |
| [Peel](https://github.com/TuguiDragos/Peel) | SwiftUI cleaner | GPL-3.0 | macOS 26+, Swift 6.4, local package core |
| [mac-cleanup-py](https://github.com/mac-cleanup/mac-cleanup-py) | Python CLI | Apache-2.0 | Simple module list |
| [mac-cleaner-cli](https://github.com/guhcostan/mac-cleaner-cli) | Node CLI | MIT | Risk labels, optional backup folder |
| [Clean Me](https://github.com/Kevin-De-Koninck/Clean-Me) | AppKit | MIT | Archived 2021 |

Because several are copyleft or source-available, we take **facts** (paths,
categories, failure stories), not code.

### 3.1 What they check

Merged across all tools (full table in `docs/research/A-cleanup-tools-targets.md` §9):

- User caches, sandbox container caches, group container caches, saved app state.
- System caches and logs, crash reports, diagnostic databases (root).
- Trash, including volume Trashes.
- Browser caches (Safari, Chrome and every Chromium browser, Firefox `cache2`), never profiles.
- App caches: chat, meetings, creative, media, games, office, cloud sync clients.
- Developer: Xcode, simulators, SwiftPM, Homebrew, npm, Yarn, pnpm, Bun, pip, uv, Poetry, Cargo, Go, Gradle, Maven, CocoaPods, Ruby, Composer, Docker, Android, JetBrains, AI-agent old versions, project build folders.
- Mail attachment copies; Messages previews only.
- iOS backups, IPSW firmware, macOS installers.
- Time Machine snapshots, purgeable, DNS cache, `purge` (memory).
- Language packs and architecture stripping (breaks signatures).
- App leftovers, orphans, broken launch agents, `.DS_Store`, incomplete downloads, large/old files, duplicates.

### 3.2 What we bring in

| Idea | From | How we use it |
|---|---|---|
| Allow-list of roots plus a protected overlay | PureMac, Mole | Every rule names its roots; a global protected list always wins |
| Same checks in preview and in the real run | Mole | One `SafetyGate` used by both |
| "Unknown means keep" | Mole | Timeouts, unreadable dates or unknown app state never delete |
| Age thresholds per rule | Mole | Logs 7 d, crash reports 7 d, Mail downloads 30 d, installers 14 d |
| Re-check at delete time (owner running, open files, inode) | Mole | `SafetyGate` re-verifies just before each item |
| Delete children, keep the folder | Mole #1689 | Never remove a rule's root folder |
| Owner commands first | Mole | `brew cleanup`, `xcrun simctl`, `docker … prune`, `go clean`, `npm cache clean`, `pnpm store prune` |
| Keep newest N | Mole | DeviceSupport keep 2 per platform |
| Mail Downloads "unedited copy" rule | Mole | Skip files modified after Mail saved them |
| Trash by default + restore history | MacSai | Plus "empty only our items" |
| Data-driven rules with recommend/default flags | Lemon | Rules are Swift data tables with tier and default |
| Container ID from `.com.apple.containermanagerd.metadata.plist` | Pearcleaner | Map UUID containers to bundle IDs |
| Leftover search roots and depth limits | Pearcleaner, Lemon | Wave 6 uninstaller |
| Whole-name match, not substring; minimum length | Lemon, Pearcleaner | Wave 6 uninstaller |
| `pkgutil` receipts: delete a folder only when every item is listed | Lemon | Wave 6 uninstaller |
| SIP flags check (`SF_RESTRICTED`, `SF_NOUNLINK`) | PureMac | Skip as "Protected by macOS" |
| Tri-state FDA, real `EPERM` as truth | ClearDisk notes | Access module |
| Review-only tier | Mole | Archives, backups, runtimes, Gradle, Maven, models |

### 3.3 Mistakes we must not repeat

| Incident | Lesson (our rule) |
|---|---|
| Mole #823: deleted `~/.claude/projects/*/memory` | AI agent state folders are protected |
| Mole #1689: deleted the `DiagnosticReports` folder itself | Delete children only |
| Mole #1854: deleted Kitty's cache while it ran | Skip when the owner app runs |
| Mole #1670, #1590: "orphan" prefs and live app data trashed | Never infer ownership from a name |
| Mole #1584: Spotlight timeout cached as "not installed" | Never cache a negative; timeout = keep |
| Mole code note: staged update removal left a Mac unbootable | Never touch `/Library/Updates` or `macOS Install Data` |
| Pearcleaner #618: `com.apple.pixelmator` matched all `com.apple` data | Apple prefixes never match in leftovers |
| Pearcleaner #587: deleted `~/Documents/OpenSCAD` | Never search Documents/Desktop for leftovers |
| Pearcleaner #506: Firefox Nightly removed stable Firefox profiles | Shared vendor folders need every sibling app absent |
| Pearcleaner #616: moved a system-owned item into Trash, Trash could not be emptied | Check deletability before moving |
| Pearcleaner helper runs any string via `bash -c` as root | A future helper takes fixed operations only, verifies caller team ID |
| Lemon daemon accepts any XPC client | Same |
| Lemon #149: said "moved to Trash" but deleted permanently | The UI reports exactly what happened per item |
| PureMac #144: removing `.lproj` broke signatures | Never edit app bundles |
| PureMac #48: trusted `HOMEBREW_CACHE` | Environment and CLI output are not trusted delete targets |
| Pearcleaner phishing site | Only link GitHub Releases; checksums and attestations |

---

## 4. Fast scanning (to be measured in spike S1)

The plan's starting design, from known APIs:

- `getattrlistbulk(2)` returns many directory entries with their attributes in
  one call. Ask for name, object type, device ID, file ID, flags, link count,
  allocated size and logical size.
- Workers: a bounded pool (about the number of performance cores, max 8), one
  reusable 256 KB buffer each, a shared queue of directories.
- Count hard-linked files once by `(device, fileID)`, only when link count > 1.
- Stop at volume boundaries by comparing device IDs; scan
  `/System/Volumes/Data` rather than `/` to avoid firmlink double counting.
- Report allocated size. APFS clones share blocks, so freed space can be less
  than the sum; show the real before/after free-space delta after each clean.
- Keep folder totals to a set depth and a top-N file heap; no per-file objects.
- Most screens scan only the catalog's roots, which is what keeps the app fast.
  A full-volume scan runs only for Space Lens and the "Unexplained" number.

---

## 5. Signing and distribution

| | Ad-hoc (now) | Developer ID (later, paid) |
|---|---|---|
| First launch | `install.sh` via `curl` (no quarantine) or DMG + "Open Anyway" | Normal prompt |
| Homebrew official cask | No (Gatekeeper requirement since Sept 2026) | Yes |
| Privileged helper | No (`SMAppService` needs a stable identity) | Yes |
| FDA grant across updates | Likely lost each update (identity is the code hash) | Kept |
| Sparkle | Works with EdDSA keys | Works, key rotation possible |
| CI secrets | None | Cert, API key, ephemeral keychain |
