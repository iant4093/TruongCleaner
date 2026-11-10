# TruongCleaner: Implementation Plan

Status: **v1.0 shipped** (2026-11-09). Planned 2026-11-06; the waves below are done except where `tasks.md` says otherwise.
Owner: Ian Truong (`iant4093`). Repo: [iant4093/TruongCleaner](https://github.com/iant4093/TruongCleaner).
Style reference: [iant4093/TruongCam](https://github.com/iant4093/TruongCam) (README, scripts, CI/CD).

Read with:

- `docs/RESEARCH.md`: what we learned and what we adopt from other tools.
- `docs/RULE_CATALOG.md`: what the app scans and cleans, and at what risk tier.
- `docs/UI.md`: screens and the System Settings / Liquid Glass look.
- `.kiro/steering/safety.md`: the safety rules no task may break.
- `.kiro/specs/truongcleaner/`: requirements (EARS), design, tasks.

---

## 1. Product in one paragraph

TruongCleaner is a small, fast, native macOS app that shows where disk space
went and frees it safely. It explains what Apple's Storage settings hide in
"System Data" (APFS snapshots, Spotlight index, simulator runtimes, caches,
logs, iOS backups, Docker images, AI assets), cleans what is safe to clean,
and tells the user the Apple-approved way to handle what no app may touch. It
looks like System Settings: a sidebar with colored icon tiles, grouped forms,
and Liquid Glass controls. By default it moves files to the Trash, records
every action, and can undo it.

---

## 2. Decisions

"Open" means a default is set, but Ian should confirm it (section 11).

| ID | Decision | Why |
|---|---|---|
| D1 | This Kiro Crew session (Opus 5.5) is the orchestrator and code reviewer. Sonnet 5.5 builders implement each task from a written brief. A task is done only after the orchestrator's review passes. | Ian's request; same setup that shipped FrankenTTY. See section 9. |
| D2 | Swift 6.4, Swift 6 language mode, complete strict concurrency, warnings as errors. Built with Xcode 27.0. | Matches TruongCam; catches data races at compile time. |
| D3 | Minimum macOS **26.0**, **arm64 only**. | Every Liquid Glass API is macOS 26.0. The macOS 27 SDK adds no new SwiftUI glass API (checked in the installed SDK). macOS 27 dropped Intel. |
| D4 | **SwiftUI** for all UI, with `@Observable` models. AppKit only for the calls listed in `tech.md` (icons, Reveal in Finder, panels, pasteboard, running apps, update relaunch). Trash uses `FileManager.trashItem` (S3). | Native look for free; standard controls adopt Liquid Glass automatically. |
| D5 | **Not sandboxed**, distributed outside the Mac App Store. | App Store rule 2.4.5 requires a sandbox, bans root and bans outside updates. A sandboxed cleaner cannot see most caches. |
| D6 | **Zero third-party runtime dependencies.** System frameworks only (SwiftUI, Charts, Foundation, Darwin, AppKit, ServiceManagement later). | Small and fast; TruongCam's "0 runtime dependencies" badge. |
| D7 | Core logic lives in a local SwiftPM package `Packages/CleanerKit` (CleanerCore, CleanerScanner, CleanerActions). The app target is thin. | Headless `swift test` on CI; clean module boundaries for parallel builders. |
| D8 | **Swift Testing** for all package tests. Tests build fixture folder trees under `build/`; they never touch the real home folder. | Parameterized tests suit rule tables. No real deletion on Ian's Mac. |
| D9 | Default delete action is **Move to Trash**, with a history log and Undo. "Free space now" then empties *only the items TruongCleaner moved*. Permanent delete is opt-in per clean. | Reversible by default, yet space is really freed. Mole and Lemon delete permanently and have data-loss reports. |
| D10 | **No privileged helper in v1.** Root-only items (Time Machine snapshots, Spotlight index, `/Library/Caches` owned by root) show as *Info* rows: size, explanation, Apple's way to fix it, a copyable command. | A helper needs a stable Developer ID signature; ad-hoc signing changes identity every build (verified). |
| D11 | **Full Disk Access is optional.** Detection is tri-state (granted, not granted, unknown). Any `EPERM` marks that row "Needs access" with a button to the FDA pane. | No public API to ask; the old TCC.db probe is dead on macOS 27; Apple plans more FDA controls. |
| D12 | The scanner uses `getattrlistbulk(2)` with a bounded worker pool, allocated sizes, hard-link de-duplication, and no crossing of volumes. Confirmed by spike S1 (7.3× `du`). | Fewest system calls per file; to be proven by measurement on this Mac. |
| D13 | The rule catalog is **our own data**, written from facts in `docs/RESEARCH.md`. No code is copied from any other cleaner. | Mole, Lemon and Peel are GPL; Pearcleaner has a Commons Clause; System Data Unpacked is all rights reserved. |
| D14 | Repo layout, README, `scripts/` and CI/CD follow TruongCam. CI runs on GitHub's `xcode-27` image. Pushes to `main` that pass every gate publish a Latest release. | Ian's format. |
| D15 | Release assets: `TruongCleaner.dmg`, `TruongCleaner.zip`, `install.sh`, `TruongCleaner.dSYM.zip`, `SHA256SUMS`, with build provenance attestations. | One-command install plus a normal DMG. |
| D16 | No telemetry. The only network call is a daily check of the GitHub Releases API for a newer build, which the user can turn off. | Privacy; zero dependencies. |
| D17 | Signing: **ad-hoc** for now (Q1). | $0 and no secrets, like TruongCam. Developer ID later changes the path in section 6. |
| D18 | License: **MIT** (Q4). | Same as FrankenTTY. |
| D19 | Updates: notify-only checker, no Sparkle (Q2; superseded by D20). App Uninstaller after 1.0 (Q3; superseded by D20). Orchestrator may push to `main` (Q5). | Ian, 2026-11-06. |
| D20 | Updates install from inside the app (Settings > General, Overview banner): download, SHA-256 check, signature check, swap the bundle, relaunch. Still no Sparkle. App Uninstaller moves into 1.0 (`docs/UNINSTALLER.md`). | Ian, 2026-11-09. |
| D21 | In-app updates also need `SHA256SUMS.sig`: an Ed25519 signature over `SHA256SUMS`, made on Ian's Mac with a key in his login Keychain (`scripts/release-key.swift`, `scripts/sign-release.sh build-N`, which first checks the CI build attestation). The app embeds the public key (`UpdateTrust.productionPublicKeys`) and refuses unsigned or badly signed updates. CI never holds the key. `install.sh` is unchanged (it comes from the same release). | Ian, 2026-11-10 (safety review #3). |

---

## 3. Feature scope

### 3.1 In v1.0

| Area | What the user gets |
|---|---|
| Overview | A storage bar like System Settings, with our own breakdown (Apps, Documents, Developer, Caches, Logs, iOS backups, Trash, Snapshots, Purgeable, and a computed "Unexplained" remainder). Top recommendations with sizes. |
| Smart Clean | One scan of all *Safe* rules, grouped by category, with per-item sizes. Safe items pre-selected, Review items not. One "Clean" button. |
| System Data | Each System Data contributor with its size, what it is, whether it is safe, and the action: clean, open the right Settings pane, run an owner command, or copy a command. |
| Developer | Xcode (DerivedData, DeviceSupport keep newest 2, previews, caches), simulators via `xcrun simctl`, package manager caches (npm, Yarn, pnpm, pip, uv, Cargo, Go, Gradle, CocoaPods, SwiftPM, Homebrew), Docker via its own CLI, project build folders inside folders the user picks. |
| Large & Old Files | Files over a size and age you choose, in folders you choose. Review only; nothing pre-selected. |
| Space Lens | A sunburst of any folder, drill-down, Reveal in Finder, Quick Look, move to Trash. |
| Trash | Size of the Trash, empty it, or empty only TruongCleaner's items. |
| History | Every clean: what moved, where, size, and Undo while the item is still in the Trash. |
| Settings | Exclusions, age thresholds, delete mode, update check, Full Disk Access status. |

### 3.2 After v1.0 (planned, not promised)

| Area | Note |
|---|---|
| ~~App Uninstaller with leftovers~~ | Shipped in 1.0 (D20, `docs/UNINSTALLER.md`). |
| Privileged helper | Only after a Developer ID decision. Would cover snapshot thinning, Spotlight rebuild, root caches. |
| Menu bar extra | Free space at a glance. |
| Homebrew tap | Needs Developer ID for the official cask repo; a personal tap works without it. |
| Duplicate finder | Hash-based, review only. |

### 3.3 Never

- Deleting or editing anything inside an app bundle (language packs, architecture stripping). It breaks code signatures.
- Touching iCloud Drive, CloudStorage, Photos libraries, Mail stores, Messages attachments, Keychains, password managers, or AI-agent memory folders.
- Asking the user to turn off SIP.
- "Memory cleaning", "speed boost", or fake alerts.

---

## 4. Architecture

Details and type sketches: `.kiro/specs/truongcleaner/design.md`.

```text
TruongCleaner.app (SwiftUI, @MainActor view models)
   │ async calls, AsyncStream progress
   ▼
CleanerKit (local SwiftPM package, no UI)
   ├─ CleanerCore     models, rule catalog, path policy, byte formatting   (pure)
   ├─ CleanerScanner  bulk directory walker, sizing, volume and snapshot info, access probe
   └─ CleanerActions  safety gate, Trash executor, owner-command runner, history, undo
Dev-only executable: tcbench (benchmarks for docs/EVIDENCE.md, not shipped)
```

Rules:

- Every deletion goes through one function, `SafetyGate.authorize(_:)`, then one executor. No other code may call `removeItem`, `trashItem`, `unlink` or `rm`.
- The scanner never runs on the main actor. Heavy functions are `@concurrent` or actor-isolated.
- Progress reaches the UI at most 10 times a second.
- The app holds sizes per folder up to a set depth plus a top-N file heap, never one object per file.

---

## 5. Performance and size budgets

Measured numbers go to `docs/EVIDENCE.md`. Targets marked "S1" are set after spike S1.

| ID | Budget | Target |
|---|---|---|
| P1 | Cold launch to first frame | < 400 ms |
| P2 | Idle | 0% CPU, no timers, no background scanning |
| P3 | Memory, idle / during a full Data-volume scan | < 60 MB / < 250 MB |
| P4 | Smart Clean scan (all catalog roots, warm cache) | < 5 s on Ian's Mac |
| P5 | Full scan throughput | S1; must beat `du -sk` on the same tree |
| P6 | App bundle | < 5 MB (a bare SwiftUI + Charts app measured 140 KB) |
| P7 | UI | No main-thread work over 16 ms during a scan |

---

## 6. Distribution, install and updates

### 6.1 Install (ad-hoc signed, today)

```bash
curl -fsSL https://github.com/iant4093/TruongCleaner/releases/latest/download/install.sh | sh
```

`install.sh` downloads `TruongCleaner.zip` and `SHA256SUMS` from the same
release, checks the hash, stops on mismatch, quits a running copy, replaces
`/Applications/TruongCleaner.app` (or `~/Applications` if `/Applications` is
not writable), and opens it. Files fetched by `curl` carry no quarantine flag,
so Gatekeeper does not block first launch (confirmed on macOS 27, EVIDENCE S7).

The DMG is also offered. DMG users must open the app once, then use **System
Settings > Privacy & Security > Open Anyway** (Control-click Open was removed
in macOS 15).

### 6.2 Updates

The app checks `api.github.com/repos/iant4093/TruongCleaner/releases/latest`
at most once a day, compares the build number, and shows a banner with the
release notes. **Superseded by D20:** the app downloads, verifies and installs the update itself (Settings > General > Install Update).

### 6.3 What changes with a paid Developer ID (Q1)

Notarized DMG with no "Open Anyway", official Homebrew cask, stable Full Disk
Access grants across updates, and the privileged helper becomes possible. CI
gains secrets: Developer ID `.p12`, App Store Connect API key, ephemeral keychain.
Keep the bundle ID `com.iant4093.TruongCleaner` stable from release 1 so the
switch is an update, not a new app.

---

## 7. CI/CD (`.github/workflows/ci.yml`)

Same shape as TruongCam: SHA-pinned actions, `permissions: contents: read` by
default, short artifact retention, Dependabot weekly for `github-actions`,
publish only from `main`.

| Job | Runner | Steps |
|---|---|---|
| `quality` | `ubuntu-latest` | `scripts/check-workflows.sh` (actionlint, shellcheck, zizmor, Gitleaks); CodeQL for `actions` |
| `logic` | `xcode-27` | `scripts/lint.sh` (pinned SwiftLint, checksum-verified); `scripts/test.sh package` (Swift Testing, `swift test --package-path Packages/CleanerKit`) |
| `app` | `xcode-27` | Print and check Xcode 27 + macOS SDK ≥ 27; `scripts/build.sh` Debug and Release (`CODE_SIGNING_ALLOWED=NO`); `xcodebuild analyze`; `scripts/package.sh`: ad-hoc sign inside-out, `codesign --verify --strict`, `lipo -archs` = `arm64`, `vtool` platform MACOS, min OS 26.0, no embedded frameworks, DMG + ZIP + dSYM zip + `install.sh` + `SHA256SUMS`; attest on `main`; upload release candidate |
| `release` | `ubuntu-latest`, `main` only, needs all | Verify `SHA256SUMS`; skip if a newer commit is on `main`; create `build-N` draft, upload, mark Latest; title `TruongCleaner · Build <1000+N>` |

Notes:

- There is no `macos-27` label. macOS 27 is only on `xcode-27`.
- CodeQL cannot scan Swift 6.4 / Xcode 27 (GitHub changelog 2026-10-19). Same as TruongCam: CodeQL on workflows; the compiler, SwiftLint, tests and the Xcode analyzer cover the app.
- The image's default Xcode is 27.1 while Ian's Mac has 27.0. Decision: accept the image default (not pinned); every CI run since build 1 has passed with zero source warnings.
- Public repo: hosted macOS minutes are free.

---

## 8. Waves

Each wave ends with: CI green on `main`, a release published, the
orchestrator's review recorded in `docs/EVIDENCE.md`, and a hand check by Ian
where marked ✋. Task-level detail is in `.kiro/specs/truongcleaner/tasks.md`.

| Wave | Goal | Exit criteria |
|---|---|---|
| **0. Spikes** | Prove the risky assumptions on this Mac before building on them. | S1–S8 below answered with evidence. |
| **1. Foundation** | Repo, Xcode project, CleanerKit package, scripts, CI/CD, README, empty System-Settings-style window. | First Latest release installs with `install.sh` ✋. |
| **2. Scanner + Overview** | Fast walker, volume numbers (free, purgeable, snapshots), storage bar, Overview screen. | P1–P5 measured; Overview totals reconcile with `df` within 1%. ✋ |
| **3. Clean engine + Smart Clean** | Path policy, safety gate, Trash executor, history and Undo, Safe/Review rules for caches, logs, Trash, browsers, app caches. | Every safety rule in `safety.md` has a test that fails without it; a real clean and undo on Ian's Mac ✋. |
| **4. System Data + Developer** | Info rows (snapshots, Spotlight, swap, AI assets, updates), iOS backups and firmware, installers, Docker, Xcode and simulators, package caches, project build folders. | "Unexplained" remainder shown and explained; owner commands run with argv, timeouts and a clean env. ✋ |
| **5. Large files, Space Lens, Trash, Settings** | The remaining v1 screens. | Sunburst draws 100k nodes at 60 fps or degrades gracefully. ✋ |
| **6. App Uninstaller** (optional for 1.0) | Strict leftovers finder. | Regression tests for every known incident in research B §1.9. |
| **7. Polish + 1.0** | Onboarding, Full Disk Access flow, accessibility (VoiceOver, Reduce Transparency, Increase Contrast), app icon (Icon Composer), screenshots, final README. | v1.0.0 release ✋. |

### 8.1 Wave 0 spikes

Spikes live in `spikes/` and are never imported by the app. Each writes its
result to `docs/EVIDENCE.md`.

| ID | Question | Method |
|---|---|---|
| S1 | Fastest safe walker? | `tcbench` on `~/Library` and the whole Data volume: `getattrlistbulk` vs `FileManager.enumerator` with prefetched keys vs `fts`, each single- and multi-threaded. Files/s, peak RSS, totals vs `du -sk`. |
| S2 | Which Full Disk Access probes work on macOS 27? Does the deep link `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` open the right pane? | Ad-hoc test app; Ian grants and revokes FDA ✋. |
| S3 | `FileManager.trashItem` vs `NSWorkspace.recycle`: does Finder's "Put Back" work? Name collisions? Speed for 10k items? | Fixture tree. |
| S4 | Which volume numbers can a user process read? | `URLResourceKey` capacities (available vs important vs opportunistic), `statfs`, `getattrlist ATTR_VOL_SPACEUSED`, `tmutil listlocalsnapshots /`, `diskutil apfs list -plist`. Compare with System Settings > Storage ✋. Check whether macOS 27 counts purgeable in System Data. |
| S5 | Does our SwiftUI window look like System Settings? | Prototype sidebar + grouped form + icon tiles + glass toolbar; screenshot beside System Settings ✋. |
| S6 | Does the Xcode project (file-system synchronized groups, objectVersion 77) build headless on `xcode-27`, ad-hoc sign, and package? | Push to a scratch branch; run CI. |
| S7 | Does `curl … | sh` install launch with no Gatekeeper prompt on macOS 27? What does the DMG path look like? | Ian runs both ✋. |
| S8 | Does `kiro-cli chat --v3 --agent builder-sonnet --no-interactive` load `.kiro/hooks` in this repo, and is `--trust-workspace` needed? | Dispatch a no-op brief; read `build/hooks/hooks.log`. |

---

## 9. Multi-agent setup

| Role | Who | Owns |
|---|---|---|
| Orchestrator and reviewer | This Kiro Crew session, Claude Opus 5.5 (`architect-opus` config for CLI use) | `.kiro/`, `docs/`, `README.md`, `AGENTS.md`, `.github/`, `scripts/hooks/`, `LICENSE`, `.gitignore`, `.swiftlint.yml`, git (commits, pushes, releases) |
| Builders | `builder-sonnet`, Claude Sonnet 5.5, via `kiro-cli` | `src/`, `Packages/`, `scripts/` (except `scripts/hooks/`), `spikes/`, `TruongCleaner.xcodeproj/`, `docs/screenshots/` |

Flow (full protocol in `.kiro/steering/agent-roles.md`):

1. The orchestrator writes a brief in `docs/briefs/<task-id>.md` from `docs/briefs/TEMPLATE.md`.
2. It dispatches the builder:
   `kiro-cli chat --v3 --agent builder-sonnet --no-interactive --trust-tools=fs_read,fs_write,shell,execute_bash,grep,glob "$(cat docs/briefs/<task-id>.md)"`
   (add `--trust-workspace` if S8 shows it is needed). Independent briefs with
   disjoint file sets may run in parallel; overlapping ones run in order.
   Kiro Crew `spawn_run` with `model: claude-sonnet-5.5` is the fallback if the CLI path fails.
3. Hooks run `swift build` after writes and block the builder's turn until lint, package tests and the Debug build pass (max 3 blocks). A safety hook blocks shell commands that could delete or clean real data.
4. The builder reports files changed, tests added, commands and results, deviations, open questions.
5. The orchestrator reviews against the checklist in `agent-roles.md`, reruns the checks, records findings in `docs/EVIDENCE.md`, then commits or sends a follow-up brief.

---

## 10. Risks

| Risk | Effect | Mitigation |
|---|---|---|
| A rule deletes live data | Data loss, lost trust | Allow-list rules only; protected overlay; liveness checks at delete time; Trash by default; regression test per known incident from other tools. |
| macOS 27 blocks other teams' containers and some Application Support folders | Rows show 0 or fail | Treat `EPERM` as "Needs access", never as 0. |
| Apple tightens Full Disk Access | FDA flow breaks | FDA code isolated in one module; the app is useful without FDA. |
| Ad-hoc identity changes each build | FDA must be re-granted after each update | Document it; Developer ID fixes it (Q1). |
| APFS clones and snapshots make sizes misleading | "Freed" number lies | Show allocated size; label estimates; measure real free space before and after each clean and show the true delta. |
| Ian's disk has about 60 GB free | Large local builds and spikes can fill it | Build outputs under `build/`, cleaned by `scripts/clean.sh`; no simulator runtimes needed (macOS-only app). |
| CI Xcode differs from local | New warnings fail the build | Print versions; decide pin in Wave 1. |
| A fake download site (as happened to Pearcleaner) | Users get malware | Only link GitHub Releases; publish `SHA256SUMS` and attestations; README says so. |

---

## 11. Questions for Ian (answered 2026-11-06: defaults, push allowed)

| ID | Question | Answer |
|---|---|---|
| Q1 | Will you pay for an Apple Developer ID? | No, for now. Ad-hoc; no helper; install via `install.sh` |
| Q2 | Sparkle 2 auto-update (+3 MB, one dependency) or a notify-only checker (zero deps)? | Notify-only at first; in-app install without Sparkle since D20 |
| Q3 | Ship the App Uninstaller in 1.0, or after? | After 1.0 at first; moved into 1.0 on 2026-11-09 (D20) |
| Q4 | MIT license? | MIT, copyright "Ian Truong" |
| Q5 | May the orchestrator push straight to `main` in this repo? | Yes |
