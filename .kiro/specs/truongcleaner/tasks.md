# Tasks

Legend: `[ ]` open, `[~]` in progress, `[x]` done (review passed). Owner: **O**
orchestrator, **B** builder-sonnet, **I** Ian (hand check). "Par" = tasks with
the same letter in a wave may run in parallel (disjoint files).

A task is checked only after the orchestrator's review. Each B task gets a
brief in `docs/briefs/<id>.md`.

## Wave 0: Spikes

| ✓ | ID | Owner | Par | Task | Output |
|---|---|---|---|---|---|
| [x] | 0.1 | O | | Confirm builder dispatch: no-op brief, check hooks fire (S8) | `docs/EVIDENCE.md` S8 |
| [x] | 0.2 | B | a | S1 walker benchmark: `spikes/s1-walker/` SwiftPM exe; `getattrlistbulk` vs `FileManager.enumerator` (prefetched keys) vs `fts`, 1 and N workers, on `~/Library` and `/System/Volumes/Data` (read-only); compare with `du -sk` | Table: files/s, wall time, peak RSS, total bytes vs `du` |
| [x] | 0.3 | B | b | S3 Trash behavior: `spikes/s3-trash/` on a fixture folder in `spikes/s3-trash/out/`; `trashItem` vs `NSWorkspace.recycle`; collisions; 10k items timing; record resulting URLs | Recommendation + numbers |
| [x] | 0.4 | B | c | S4 volume numbers: `spikes/s4-volume/` prints every capacity key, `statfs`, `ATTR_VOL_SPACEUSED`, `tmutil listlocalsnapshots /`, `diskutil apfs list -plist` summary | Numbers; I compares with System Settings ✋ |
| [x] | 0.5 | B | d | S5 UI prototype: `spikes/s5-ui/` SwiftUI app with sidebar, icon tiles, grouped form, glass toolbar and clean bar; screenshots light/dark | Screenshots beside System Settings; I approves ✋ |
| [x] | 0.6 | B | e | S2 FDA probe app: `spikes/s2-fda/` reports each probe result and opens the deep link | I grants/revokes FDA, reports ✋ |
| [x] | 0.7 | O | | S6 CI proof: minimal Xcode project + package on a scratch branch through `xcode-27`; record Xcode version used | CI log link |
| [x] | 0.8 | I | | S7 install proof: run `install.sh` from the scratch release and open the DMG path | Notes ✋ |
| [x] | 0.9 | O | | Update PLAN decisions D9, D12 and budgets P5 from spike results | PLAN diff |

## Wave 1: Foundation

| ✓ | ID | Owner | Par | Task | Reqs |
|---|---|---|---|---|---|
| [x] | 1.1 | B | | Xcode project (objectVersion 77, synchronized groups), app target `TruongCleaner`, bundle ID `com.iant4093.TruongCleaner`, macOS 26.0, arm64, Swift 6, warnings as errors, links local `CleanerKit`; empty `NavigationSplitView` window with the sidebar from `docs/UI.md` §3 and `IconTile` | UI-01 |
| [x] | 1.2 | B | | `Packages/CleanerKit` skeleton: three library targets, `tcbench` exe, test targets, `Fixtures` helper (`FixtureTree`), one passing test per target | — |
| [x] | 1.3 | B | a | `scripts/`: `lint.sh` (pinned SwiftLint + checksum), `test.sh package`, `build.sh {debug,release,all}`, `package.sh` (ad-hoc sign, verify, DMG, ZIP, dSYM zip, SHA256SUMS), `install.sh`, `check-workflows.sh`, `check-deletion-sites.sh`, `clean.sh` (removes `build/` only) | DIST-01, DIST-03, SAFE-01 |
| [x] | 1.4 | O | a | `.github/workflows/ci.yml`, `dependabot.yml`, `actionlint.yaml`, `.swiftlint.yml`; SHA pins | CI-01..04, DIST-02 |
| [x] | 1.5 | O | | README in TruongCam format; LICENSE; first push (after Q5) | — |
| [x] | 1.6 | I | | Install the first Latest release with `install.sh` ✋ | — |

## Wave 2: Scanner + Overview

| ✓ | ID | Owner | Par | Task | Reqs |
|---|---|---|---|---|---|
| [x] | 2.1 | B | a | `BulkWalker` + `WalkPool` + `SizeAccumulator` (or S1's winner) with fixture tests: totals, hard links, symlinks, unreadable dirs, cancellation, device boundary | SCAN-02..07, SCAN-09 |
| [x] | 2.2 | B | b | `VolumeInfo`, `Snapshots`, `ReadOnlyCommand` with parser tests on captured output | SYS-01, SYS-02 |
| [x] | 2.3 | B | c | CleanerCore models + `PathPolicy` + `ByteFormatter` + catalog well-formedness tests (catalog empty but shaped) | RULE-01 |
| [x] | 2.4 | B | | `ScanEngine` + `Matcher` (needs 2.1, 2.3) | SCAN-01, SCAN-08, RULE-03, RULE-04 |
| [x] | 2.5 | B | | Overview page: storage bar (Charts), details, recommendations placeholder | SYS-01, SYS-03, UI-02 |
| [x] | 2.4b | B | | Nested rule overlaps (`coveredByOtherRule`) and pruned project walks | SCAN-07 |
| [x] | 2.6 | B | | `tcbench` scenarios; numbers into EVIDENCE | PERF-01..05 |
| [x] | 2.6b | B | | Investigate cancel latency on a 3-core runner (CI saw 3.3 s for a 200 ms budget in `cancellingTheStreamConsumerEndsPromptly`): look for cooperative-pool starvation (semaphore waits in `ReadOnlyCommand`/`OwnerProcess`, `WalkPool` condition waits) and measure with `taskpolicy`/limited cores | SCAN-05 |
| [x] | 2.7 | I | | Overview totals vs `df` and System Settings ✋ | — |

## Wave 3: Clean engine + Smart Clean

| ✓ | ID | Owner | Par | Task | Reqs |
|---|---|---|---|---|---|
| [x] | 3.1 | B | a | `SafetyGate`, providers protocols, `SkipReason`; `SafetyRulesTests` covering `safety.md` 1–16 and `RESEARCH.md` §3.3 incidents | SAFE-01..12 |
| [x] | 3.2 | B | b | Catalog: caches, logs, trash, browsers, apps rules with rule-obligation tests | RULE-01..04 |
| [x] | 3.3 | B | | `TrashExecutor`, `DeleteExecutor`, `History`, `Undo`, `Cleaner.run/preview` (needs 3.1) | CLEAN-01..05 |
| [x] | 3.4 | B | | App `RunningApps` + `OpenFiles` providers (`proc_listpidspath`) | SAFE-07, SAFE-08 |
| [x] | 3.5 | B | | Smart Clean page, clean bar, confirm dialog, result sheet with measured delta | CLEAN-02, CLEAN-06, UI-03, UI-06 |
| [x] | 3.6 | B | | Trash + History pages, Put Back, Free Space Now | CLEAN-04, CLEAN-05 |
| [x] | 3.7 | O | | Independent safety review by a fresh reviewer agent with no session context | — |
| [x] | 3.8 | I | | Real clean + undo on items Ian picks ✋ | — |

## Wave 4: System Data + Developer

| ✓ | ID | Owner | Par | Task | Reqs |
|---|---|---|---|---|---|
| [x] | 4.1 | B | a | Info rules (`system.*`, `logs.system`, `mail.store`, …) + System Data page + Copy Command | SYS-03..05 |
| [x] | 4.2 | B | b | Developer rules (Xcode, SwiftPM, npm, Yarn, Bun, pip, uv, Cargo, Gradle, Maven, CocoaPods, Android) | RULE-01 |
| [x] | 4.3 | B | c | `OwnerCommand` runner + `dev.simUnavailable`, `dev.simDevices`, `dev.simRuntimes`, `dev.homebrew`, `dev.pnpm`, `dev.go*`, `dev.dockerDangling` (tests use fake executables in fixtures) | CLEAN-07 |
| [x] | 4.4 | B | | Mail, iOS, installers rules | RULE-01 |
| [x] | 4.5 | B | | Developer page with simulators table and project folders | UI-02 |
| [x] | 4.6 | B | | Overview and System Data: add measured home categories (Applications, Documents, Downloads, Library caches, Developer, iOS backups) so "Unexplained" shrinks to the real remainder | SYS-03 |
| [x] | 4.7 | I | | System Data page vs System Settings ✋ | — |

## Wave 5: Large files, Space Lens, Settings, Access

| ✓ | ID | Owner | Par | Task | Reqs |
|---|---|---|---|---|---|
| [x] | 5.1 | B | a | Large & Old Files page (Table, Quick Look) | UI-02, UI-05 |
| [x] | 5.2 | B | b | Space Lens sunburst with drill-down (fallback to `Canvas` if Charts is slow) | PERF-07 |
| [x] | 5.3 | B | c | Settings window: delete mode, exclusions, rules, update check | RULE-05, DIST-04 |
| [x] | 5.4 | B | | `AccessProbe` + Needs Access rows + re-check on activate | PERM-01..04 |
| [x] | 5.5 | B | | Update checker (GitHub API, once per day) | DIST-04, DIST-05 |

## Wave 6: App Uninstaller (optional for 1.0, Q3)

| ✓ | ID | Owner | Par | Task |
|---|---|---|---|---|
| [x] | 6.1 | O | | Write the uninstaller spec (search roots, whole-name and bundle-ID matching, Apple-prefix exclusion, shared vendor folders, receipts) |
| [x] | 6.2 | B | | Implement with regression tests for Pearcleaner #506, #571, #587, #618 and Lemon's short-bundle-ID bug |

## Wave 7: Polish + 1.0

| ✓ | ID | Owner | Par | Task | Reqs |
|---|---|---|---|---|---|
| [x] | 7.1 | B | a | Onboarding sheet + FDA flow | PERM-02 |
| [x] | 7.2 | B | b | Accessibility pass: labels, keyboard, Reduce Transparency, Increase Contrast, Reduce Motion | UI-04, UI-05, UI-07 |
| [x] | 7.3 | B | c | App icon (Icon Composer), screenshots in `docs/screenshots/` (webp) | — |
| [ ] | 7.4 | O | | Final README, release notes, v1.0.0 | — |
| [x] | 7.5 | I | | Full hand test on Ian's Mac ✋ | — |

## Wave 8: Feedback from Ian's hand checks (2026-11-09)

| ✓ | ID | Owner | Par | Task | Reqs |
|---|---|---|---|---|---|
| [x] | 8.0 | I | | Hand checks: install, FDA, Storage numbers, look, real clean + put back + Free Space Now (history: 1,051 moved, 0 failed) | — |
| [x] | 8.1 | B | a | Shared row layout for Smart Clean, Developer, System Data; friendly app names in skip reasons | UI-02, UI-06 |
| [x] | 8.2 | B | b | Install updates from Settings and the Overview banner | DIST-04 |
| [x] | 8.3 | B | | Row polish follow-ups: System Data gap, FDA footer, applets, admin reasons, app sort | UI-02 |
| [x] | 2.8 | B | | Smart Clean speed: glob descent, shared thread budget, streaming sections (brief `2.7.md`, EVIDENCE "Task 2.7 review") | PERF-04 |

## Wave 9: v1.0 code review

| ✓ | ID | Owner | Par | Task |
|---|---|---|---|---|
| [x] | 9.0 | O | | Four independent reviews (safety, scanner, app, release): `docs/reviews/` |
| [x] | 9.1 | B | a | Safety fixes |
| [x] | 9.2 | B | b | Scanner fixes |
| [x] | 9.3 | B | c | App, updater, installer fixes; version 1.0.0 |
| [x] | 9.4 | B | | Follow-ups: leftover folders Review after measuring (documents, disk images, >1 GB, partial); gate age walk on the shared budget |
| [x] | 9.5 | O | | CI (attest job, self-test, versioned release title and notes), safety hook, README, PLAN, RULE_CATALOG, UNINSTALLER, safety.md 16a, tasks |
| [ ] | 9.6 | Ian | | Decide: sign `SHA256SUMS` with Ed25519 for in-app updates (safety review #3) |
