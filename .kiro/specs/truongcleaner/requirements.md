# Requirements: TruongCleaner v1.0

EARS format. IDs are referenced by briefs, tests and reviews. "The app" means
TruongCleaner.app; "the kit" means the CleanerKit package.

## Scanning (SCAN)

- **REQ-SCAN-01** When the user starts a Smart Clean scan, the app shall scan every enabled rule's roots and show per-category sizes as they are found.
- **REQ-SCAN-02** The scanner shall report allocated size on disk and private (clone-unshared) size, and count each hard-linked file once per `(fsid, fileID)`. Space-to-be-freed estimates shall use private size.
- **REQ-SCAN-03** The scanner shall not follow symbolic links and shall not cross into a different file system (`fsid`, not `st_dev`; S1 showed System and Data share `st_dev`) than the scan root.
- **REQ-SCAN-04** When a directory returns `EPERM` or `EACCES`, the scanner shall record it as "needs access" with its path and shall not report it as zero bytes.
- **REQ-SCAN-05** When the user presses Stop, the scanner shall stop within 100 ms and keep the partial results, marked as partial.
- **REQ-SCAN-06** The scanner shall use at most `min(8, activeProcessorCount)` concurrent workers.
- **REQ-SCAN-07** The scanner shall keep per-folder totals to a configured depth plus a top-N largest-files list, and shall not keep one object per file.
- **REQ-SCAN-08** When a full-volume scan runs, the scanner shall start at `/System/Volumes/Data` so firmlinked paths are counted once.
- **REQ-SCAN-09** The scanner shall send progress to the UI no more than 10 times per second.

## Volume and System Data (SYS)

- **REQ-SYS-01** The app shall show total, used, available, and purgeable space for the startup volume, where purgeable = important-usage available − available.
- **REQ-SYS-02** The app shall list local APFS snapshots from `tmutil listlocalsnapshots /` with their dates.
- **REQ-SYS-03** The app shall compute "Unexplained" as used space minus the sum of every measured category, and shall explain it.
- **REQ-SYS-04** For each Info rule, the app shall show its size (or "Unknown"), a plain explanation, and the sanctioned action from the catalog, and shall offer no delete action.
- **REQ-SYS-05** Where a sanctioned action needs root, the app shall offer a "Copy Command" button with the exact command and a one-line warning, and shall not run it.

## Rules (RULE)

- **REQ-RULE-01** The kit shall ship exactly the rules in `docs/RULE_CATALOG.md` §4, each with id, category, tier, roots, match, guards, access, action and explanation.
- **REQ-RULE-02** Safe items shall be selected by default; Review items shall not; Info items shall not be selectable.
- **REQ-RULE-03** When a rule has `minAge`, the kit shall only offer items whose newest modification date inside is older than `minAge`.
- **REQ-RULE-04** When a rule has `keepNewest N`, the kit shall never offer the N newest matches of each group.
- **REQ-RULE-05** The user shall be able to turn each rule off and to add folder exclusions; both shall persist.

## Safety (SAFE)

- **REQ-SAFE-01** The kit shall route every deletion through `SafetyGate`; the build shall contain no other call site of a deleting API (checked by a lint script).
- **REQ-SAFE-02** `SafetyGate` shall reject any item outside its rule's roots after resolving `..` and the parent's real path.
- **REQ-SAFE-03** `SafetyGate` shall reject any item on the global protected list or in a user exclusion.
- **REQ-SAFE-04** `SafetyGate` shall reject a rule's root folder itself and every folder named in the protected list.
- **REQ-SAFE-05** `SafetyGate` shall reject an item with a symlinked ancestor below the rule root.
- **REQ-SAFE-06** When an item's `(device, fileID)` differs from the scan, `SafetyGate` shall reject it.
- **REQ-SAFE-07** When a rule's owner is running, or its state cannot be determined, `SafetyGate` shall reject the item with reason "owner open" or "owner unknown".
- **REQ-SAFE-08** When a process has a file open inside the item, or the open-file check fails, `SafetyGate` shall reject the item.
- **REQ-SAFE-09** `SafetyGate` shall reject items with `SF_RESTRICTED`, `SF_NOUNLINK`, `UF_IMMUTABLE` or `SF_IMMUTABLE` flags and report "Protected by macOS".
- **REQ-SAFE-10** The kit shall reject any write inside a code bundle, except removing a whole app matched by `installers.macOS`.
- **REQ-SAFE-11** Preview and clean shall run the same `SafetyGate` checks.
- **REQ-SAFE-12** Any timeout, parse error or failed probe shall result in the item being kept.

## Cleaning (CLEAN)

- **REQ-CLEAN-01** By default the app shall move items to the Trash.
- **REQ-CLEAN-02** Where the user picks permanent delete, the app shall ask for a second confirmation that names the total size.
- **REQ-CLEAN-03** Before and after each clean, the kit shall write a history entry listing each item with its original path, new path (if moved), size, and outcome: moved, deleted, skipped (reason) or failed (error).
- **REQ-CLEAN-04** When a moved item is still in the Trash with the same `fileID`, the app shall let the user put it back to its original path.
- **REQ-CLEAN-05** "Free Space Now" shall permanently delete only items in the Trash that TruongCleaner moved and that still match their history `fileID`.
- **REQ-CLEAN-06** After a clean, the app shall show the measured change in available space next to the estimate.
- **REQ-CLEAN-07** Owner commands shall run with an absolute path from a fixed list, a fixed argv, a scrubbed environment and a timeout, and their exit code and output tail shall be recorded in history.

## Permissions (PERM)

- **REQ-PERM-01** The app shall report Full Disk Access as granted, not granted, or unknown, from several probes.
- **REQ-PERM-02** When any row needs Full Disk Access, the app shall show "Needs Full Disk Access" with a button that opens the Privacy pane, and a fallback text if the link fails.
- **REQ-PERM-03** When the app becomes active, it shall re-check access and rescan affected rows if the result changed.
- **REQ-PERM-04** The app shall work without Full Disk Access, with affected rows marked.

## UI (UI)

- **REQ-UI-01** The main window shall use `NavigationSplitView` with the sidebar in `docs/UI.md` §3, colored icon tiles, and a sidebar search field.
- **REQ-UI-02** Detail pages shall use grouped forms or tables from standard SwiftUI components.
- **REQ-UI-03** Liquid Glass shall appear only on the toolbar, the floating clean bar and overlay controls, using `Glass.regular`.
- **REQ-UI-04** Where Reduce Transparency is on, custom glass shall be replaced with an opaque material.
- **REQ-UI-05** Every control shall have an accessibility label, and the main flows shall work by keyboard alone (⌘R scan, ⌘⌫ clean, Space Quick Look).
- **REQ-UI-06** Every skipped or blocked item shall show its reason in plain words.
- **REQ-UI-07** The app shall support Light and Dark mode and both ends of the macOS 27 glass appearance slider without unreadable text.

## Performance (PERF)

- **REQ-PERF-01** Cold launch to first frame < 400 ms on Ian's Mac.
- **REQ-PERF-02** No CPU use and no timers while idle.
- **REQ-PERF-03** Memory < 60 MB idle and < 250 MB during a full Data-volume scan.
- **REQ-PERF-04** Smart Clean scan < 5 s with a warm file cache on Ian's Mac.
- **REQ-PERF-05** Full-scan throughput at least that of `du -sk` on the same tree (target refined by spike S1).
- **REQ-PERF-06** App bundle < 5 MB.
- **REQ-PERF-07** No main-thread stall > 16 ms during a scan.

## Distribution and updates (DIST)

- **REQ-DIST-01** CI shall build an arm64, ad-hoc-signed app with minimum macOS 26.0 and no embedded third-party frameworks.
- **REQ-DIST-02** Each passing push to `main` shall publish a Latest release with `TruongCleaner.dmg`, `TruongCleaner.zip`, `install.sh`, `TruongCleaner.dSYM.zip` and `SHA256SUMS`, with build provenance attestations.
- **REQ-DIST-03** `install.sh` shall verify the ZIP against `SHA256SUMS` from the same release and stop on mismatch.
- **REQ-DIST-04** Where the update check is on, the app shall query the GitHub Releases API at most once per day and show a banner when a newer build exists.
- **REQ-DIST-05** The app shall make no other network requests.

## CI (CI)

- **REQ-CI-01** CI shall run actionlint, shellcheck, zizmor, Gitleaks and CodeQL (actions) on every push and pull request.
- **REQ-CI-02** CI shall run SwiftLint (pinned, checksum-verified), the package tests, Debug and Release builds with warnings as errors, and `xcodebuild analyze`.
- **REQ-CI-03** All GitHub Actions shall be pinned to commit SHAs and checked weekly by Dependabot.
- **REQ-CI-04** Pull requests shall never publish.
