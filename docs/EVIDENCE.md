# Evidence

Every measurement, spike result and review finding, with date and source.
Numbers in the README or release notes must come from this file.

Format: one section per spike or task. Raw logs go in `docs/evidence/`.

## Baseline (2026-11-06, planning)

| Item | Value | Source |
|---|---|---|
| Dev Mac | macOS 27.0.1 (26A434), Apple silicon, 14 cores | `sw_vers`, resource check |
| Toolchain | Xcode 27.0 (27A266a), Swift 6.4 (swiftlang-6.4.0.34.1) | `xcodebuild -version`, `swift --version` |
| Data volume | 926 GiB, 839 GiB used, 60 GiB free (94%) | `df -h` |
| kiro-cli | 3.1.0; `--v3`, `--agent`, `--trust-tools`, `--no-interactive`, `--trust-workspace` exist | `kiro-cli chat --help` |
| Bare SwiftUI + Charts app size | 134 KB Mach-O, 140 KB `.app`, 35 KB ZIP, 54 KB DMG | Research E §2.5 (built on this Mac) |
| Ad-hoc identity | Designated requirement is a cdhash; it changed after re-signing with one extra file | Research E §3.4 |
| SwiftPM package (tools 6.4, macOS 26, warnings as errors) | Builds; `swift test` runs Swift Testing | Research E §2.1, §2.4 |
| SwiftUI glass APIs | All `macOS 26.0`; none new in the 27.0 SDK | Research E §1.2, §1.4 |
| Hook scripts | `safety-guard.sh` blocked all 7 dangerous sample commands (recursive `rm` outside `build/`, `rm` with `..`, `simctl delete`, `brew cleanup`, `sudo`, `docker … prune`, split `rm -r -f`) and allowed all 7 safe ones (`ls`, `rm -rf build/…`, `rm -rf spikes/*/out/…`, `swift test`, `tmutil listlocalsnapshots`, `git status`, `echo trash me`); shellcheck clean; agent and hook JSON valid | Orchestrator test, 2026-11-06 |

## Wave 0

### S8: builder dispatch and hooks (task 0.1, 2026-11-06)

| Check | Result | Source |
|---|---|---|
| `kiro-cli chat --v3 --agent builder-sonnet --no-interactive --trust-tools=…` runs and returns a report | Yes, exit 0 | `build/dispatch/0.1b.log` |
| `.kiro/hooks` load without `--trust-workspace` | Yes: PreToolUse `safety-guard` blocked `echo purge check`; Stop `gate-turn` ran with the real session ID | `build/hooks/hooks.log` 23:57:12Z, 23:57:19Z |
| Hook event fields | `cwd`, `hook_event_name`, `session_id`, `tool_input` (`path`, `text` for `fs_write`), `tool_name` | `build/hooks/last-fs-write-event.json` |
| Finding: agent-profile `fs_write` deny glob `README.md` also matched `spikes/s0-hooks/README.md` | Fixed: root-only files moved to the exact-path `ownership-guard` hook; re-run allowed the nested README | `build/dispatch/0.1.log`, `0.1b.log` |
| `ownership-guard` sample paths | 14 cases: 5 allowed, 9 denied, all as intended (`..`, outside repo, root files, `.kiro/`, `docs/`, unknown folder) | Orchestrator test |

Decision: dispatch without `--trust-workspace`.

### S1: directory walker benchmark (tasks 0.2, 2026-11-06)

Tool `spikes/s1-walker` (builder), run by the orchestrator with
`run-bench.sh <root> <limit>` after a warm-up pass (warm cache). The
Data-volume run overlapped with builder 1.1 compiling, so its times are
slightly pessimistic. Raw: `spikes/s1-walker/out/bench-20261106-162716.jsonl`
(`~/Library`) and the following run (Data volume).

`~/Library` (1.53 M files, 290 k dirs, 263.4 GB allocated):

| Method | Workers | Wall s | Peak RSS | Files/s |
|---|---|---|---|---|
| **getattrlistbulk** | 1 | 31.9 | 9.7 MB | 48 k |
| **getattrlistbulk** | **8** | **6.6** | **12.0 MB** | **230 k** |
| FileManager.enumerator | 1 | 43.1 | 9.9 MB | 35 k |
| FileManager.enumerator | 8 | 31.4 | 13.0 MB | 49 k |
| fts | 1 | 36.3 | 20.5 MB | 42 k |
| fts | 8 | 26.6 | 22.0 MB | 57 k |
| `du -skx` | 1 | 48.7 | 16.2 MB | n/a |

`/System/Volumes/Data` (3.40 M files):

| Method | Workers | Wall s | Peak RSS | Sum of allocated sizes |
|---|---|---|---|---|
| **getattrlistbulk** | **8** | **12.4** | **13.1 MB** | 1,652.1 GB |
| getattrlistbulk | 1 | 67.7 | 10.8 MB | 1,652.1 GB |
| fts | 8 | 57.1 | 33.1 MB | 1,652.5 GB |
| FileManager.enumerator | 8 | 86.5 | 14.5 MB | 1,652.2 GB |
| `du -skx` | 1 | 94.1 | 37.8 MB | 1,652.8 GB |

Findings:

1. **Decision D12 confirmed:** `getattrlistbulk` with 8 workers is 7.3× faster than `du` on `~/Library` and 7.6× on the whole Data volume, at about 13 MB peak memory. `bulk` and `fts` agree byte for byte where both finish.
2. **Sum-of-files overcounts on APFS.** Every walker (and `du`) sums 1,652 GB on a Data volume whose real use is 901.6 GB (S4, `ATTR_VOL_SPACEUSED`). The gap (~750 GB) is clone-shared blocks counted once per file. Scanner work in Wave 2 must use `ATTR_CMNEXT_PRIVATESIZE` (bytes freed if this file alone is deleted) alongside allocated size, and the UI must label totals honestly. A clone fixture (`cp -c`) is required in tests.
3. **`st_dev` does not separate the sealed System volume from Data** on macOS 27.0.1 (both 16777232); only `statfs.f_fsid` differs. Volume boundaries must use fsid (`ATTR_CMN_FSID`), not device ID. REQ-SCAN-03 updated in meaning: "volume" = fsid.
4. 440 (`~/Library`) and 741 (Data) directories returned `EPERM` to the agent shell (no Full Disk Access).
5. `FileManager.enumerator` gains little from parallel top-level splitting; `fts` uses 2–3× the memory.

### S4: volume numbers (task 0.4, 2026-11-06)

Builder report `build/dispatch/0.4.log`; output `spikes/s4-volume/out/summary.md`.

| Number | Value | API | User-readable |
|---|---|---|---|
| Total capacity | 994.66 GB | `volumeTotalCapacity`, `statfs`, `ATTR_VOL_SIZE` | yes |
| Available | 64.44 GB | `volumeAvailableCapacity`, `f_bavail` | yes |
| Available for important usage | 123.62 GB | `volumeAvailableCapacityForImportantUsage` | yes |
| Purgeable (derived) | 59.17 GB | important − available | yes |
| Used, whole container | 930.22 GB | URL values, `statfs` | yes |
| Used, Data volume only | 901.60 GB | `ATTR_VOL_SPACEUSED` on `/System/Volumes/Data` | yes |
| Per volume | Data 901.60, System 13.65, Preboot 10.99, VM 2.15, Recovery 1.54, Update 0.08 GB | `diskutil apfs list -plist` | yes |
| Local snapshots | 0 on this Mac | `tmutil listlocalsnapshots /` | yes (parser untested on real snapshot lines) |
| Swap | 494.6 MB of 2.15 GB | `sysctlbyname("vm.swapusage")` | yes |
| `/System/Library/AssetsV2` | ≥ 15.1 GB (3 `UAF_FM_*` folders EPERM) | walk | partly |
| `.Spotlight-V100`, `/private/var/db/oah` | exist, not listable | `lstat` ok, `open` EPERM | no |

Notes: URL/statfs values describe the whole container; only `ATTR_VOL_SPACEUSED`
and `diskutil` give per-volume use. `diskutil info` `FreeSpace`/`VolumeSize` are 0
for the sealed System volume. Whether Storage settings folds purgeable into
System Data on macOS 27 still needs Ian's look at the pane ✋.

### S2: Full Disk Access probes (task 0.6, 2026-11-06)

Builder report `build/dispatch/0.6.log`. From the agent shell (no FDA): every
protected probe returned `EPERM`; the user `TCC.db` path is `ENOENT` on macOS 27
(moved); `/Library/.../TCC.db` `EPERM`. `~/Library/Containers`: 813 children, 802
readable, 11 denied. `~/Library/Group Containers`: 152 children, 151 denied, and
probing them took **2.7 s** (denied opens are slow), so access probes must not open
every child on each activation. App for Ian: `spikes/s2-fda/out/S2FDA.app` ✋.

### S5: System Settings look prototype (task 0.5, 2026-11-06)

Builder report `build/dispatch/0.5.log`. App `spikes/s5-ui/out/S5UI.app` builds
with zero warnings and launches. `ImageRenderer` renders grouped `Form`s blank and
glass as a flat pill, so screenshots must be real window captures ✋. Tunable tile
values are in `spikes/s5-ui/Sources/S5UI/Components.swift` (`PrototypeTuning`).

### Agent sandbox note (2026-11-06)

Inside the agent sandbox, SwiftPM's manifest sandbox and the compiler's macro
plugin sandbox both fail (`sandbox_apply: Operation not permitted`). Local agent
builds need `swift build --disable-sandbox` and `xcodebuild …
OTHER_SWIFT_FLAGS=-disable-sandbox`. CI and Ian's own shell do not.

### Task 1.1 + 1.2 review (2026-11-06)

Reviewer rebuilt independently: `swift test` passes (6 tests); Debug app builds
with zero Swift warnings (with the sandbox flag). Release app: arm64, platform
MACOS, minos 26.0, SDK 27.0, only system libraries, **352 KB**. `FixtureTree`
refuses paths outside its root and symlinks. `Rule` equality is by `id` because
`LocalizedStringResource` is not `Hashable` (accepted).

### Tasks 2.1–2.3 review (2026-11-06)

Each brief ran in its own git worktree (`dispatch.sh -w`), then merged into
`main`; one conflict in `tcbench/main.swift` resolved by the orchestrator.
Merged suite: **140 tests pass** (CleanerScanner 73, CleanerCore 66, Actions 1),
zero warnings.

| Task | Result | Notes |
|---|---|---|
| 2.1 BulkWalker | 25 walker tests; `tcbench walk ~/Library/Developer --workers 8`: 88,306 files in 1.53 s, 33.66 GB allocated, 31.07 GB private, 13.3 MB peak | Totals equal across 1/4/8 workers and `du -skx`. Clone fixture: one 4 MB file + 2 clones = 12,582,912 B allocated and **0 B private** (every block shared), so private size is a lower bound and allocated an upper bound for what a deletion frees; the UI must show "up to". |
| 2.2 Volume/Snapshots/Simulators | 51 tests incl. live smoke | `tcbench volume`: 994.66 GB total, 61.72 GB available, 59.17 GB purgeable, 904.32 GB Data used, 0 snapshots, 11 simulator devices, 1 runtime (iOS 27.0, 8.07 GB). Unparseable `tmutil` output → "Unknown", never 0. |
| 2.3 PathPolicy/Matcher | 66 tests; 90 protected-list rows encoded from RULE_CATALOG §3 | Protection is case-insensitive and component-wise; `isInside` is case-sensitive (stricter). Unknown age → keep. |

### S3: Trash behavior (task 0.3, 2026-11-06)

Builder report `build/dispatch/0.3.log`; summary `spikes/s3-trash/out/summary.md`.
All moves ran on an attached 300 MB APFS image under `/Volumes`; nothing touched `~/.Trash`.

| | `FileManager.trashItem` | `NSWorkspace.recycle` |
|---|---|---|
| File / folder / symlink (link moves, target stays) | yes | yes |
| `fileID` unchanged after move | yes | yes |
| Put Back records (`ptbN`/`ptbL` in the Trash's `.DS_Store`) | yes | yes |
| 10,000 files one by one | 3.46 s, 0.29 ms mean | n/a |
| Called with the main thread blocked | works | completion never ran |
| AppKit needed | no | yes |

Decision: `FileManagerExecutor` uses `trashItem` (D9). Collisions are renamed
with a time stamp, so history stores the resulting URL. Immutable items and items
in a read-only parent fail with Cocoa 513, so the gate must check flags and parent
permissions itself. Volumes mounted outside `/Volumes` may have no `.Trashes` and
fail with 513: report as failed, never fall back to permanent delete.

### Tasks 3.1 and 2.5 review (2026-11-06)

3.1 SafetyGate: 58 tests; `safety.md` rules 2–10, 13, 15, 16 each have a test; the
builder disabled each of the 17 gate checks in turn and every one made a test
fail. `proc_listpidspath` was unreliable (exact-vnode only, ~1 in 8 false
"nothing open"), so `ProcessOpenFilesProvider` scans every process's fds with
`proc_pidinfo`/`proc_pidfdinfo` (~120 ms per call, ~1,200 processes); 3.3 must
snapshot once per clean. Open item: the bundle-extension check denies cache
folders named like `com.example.App`; fixed in 3.2b by checking for a real bundle.

2.5 Overview: builds, launches; bar segments sum to capacity (macOS volumes,
Data, purgeable, free, other volumes 206.7 MB).

Merged main: lint 0 violations (45 files), deletion-site check PASS, package
tests PASS (CleanerScanner 73+29, CleanerCore 93, CleanerActions 58), Debug app
builds (2.4 MB Debug).

### Tasks 3.2b, 4.3, 5.1, 5.2 review (2026-11-06)

Merged into `main` (keep-both conflicts in `AppModel.swift`/`RootView.swift`
resolved by the orchestrator). Merged main: lint 0 violations in 71 files,
deletion-site check PASS, package tests PASS, Debug app builds.

- 3.2b: owners per root (Chrome running blocks only Chrome's caches), owner from a
  wildcard root segment (container caches), wildcard root-segment exclusions (Apple
  containers never walked or probed), `.savedState` suffix stripping,
  `Action.deletePermanently` for Trash rules, bundle check only for real bundles
  (`com.example.App` cache folders no longer denied). `user.groupContainerCaches`
  changed Safe → Review; `trash.volumes` stays inert. Catalog updated.
- 4.3: owner-command allow-list exactly as briefed; the first existing candidate
  decides (no fall-through); `noBootedSimulator` requires every device `Shutdown`
  (unknown blocks); runtime IDs may not start with `-`. Tests use fake scripts only.
- 5.1: `LargeFileFinder` (topN by size, then date filter; reports `mayBeMissingFiles`
  when the size-ranked list could hide old files). `NSPasteboard` approved in `tech.md`.
- 5.2: Space Lens sunburst, depth 3, ≤ 40 slices per node, breadcrumb, Quick Look,
  Needs-access rows.
