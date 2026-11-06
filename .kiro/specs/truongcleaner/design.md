# Design: TruongCleaner v1.0

Companion to `requirements.md`. Type sketches are shapes, not final code;
builders may refine names inside a brief, but changes to public types need
the orchestrator's approval.

## 1. Data flow

```text
User taps Scan
  → SmartCleanModel (@MainActor) starts ScanEngine.scan(rules:) in a Task
      → ScanEngine (actor) expands each Rule's roots
          → BulkWalker workers (bounded pool) read directories with getattrlistbulk
          → Matcher (CleanerCore) applies match / depth / minAge / keepNewest / excludes
          → SizeAccumulator totals allocated bytes, de-dupes hard links
      ← AsyncStream<ScanEvent> (throttled 10/s): progress, Finding batches, needsAccess
  ← Model updates sections; user reviews selection
User taps Clean
  → CleanModel builds a CleanPlan (selected Findings + DeleteMode)
  → CleanerActions.Cleaner.run(plan)
      → History.begin(plan)
      → for each item: SafetyGate.authorize(item, rule, liveness) → Verdict
          → .allow → TrashExecutor / DeleteExecutor / OwnerCommand
          → .deny(reason) → recorded as skipped
      → History.finish(outcomes)
  ← CleanReport: per-item outcome, estimated bytes, measured free-space delta
```

## 2. CleanerCore types

```swift
public enum Tier: String, Sendable, Codable { case safe, review, info }
public enum Access: String, Sendable, Codable { case user, fda, root }
public enum Category: String, Sendable, Codable, CaseIterable {
    case caches, logs, trash, browsers, apps, developer, mail, ios, installers, system
}

public struct RootSpec: Sendable, Hashable {
    public enum Base: Sendable, Hashable { case home, absolute, darwinUserCache, darwinUserTemp }
    public var base: Base
    public var components: [String]          // may contain "*" segments
}

public enum MatchSpec: Sendable, Hashable {
    case children                            // each direct child of the root
    case glob(String)                        // relative pattern under the root
    case files(extensions: Set<String>)
    case ownerCommand(OwnerCommandSpec)      // nothing is walked; the command acts
    case measureOnly                         // Info: size the root
}

public struct Guards: Sendable, Hashable {
    public var minAge: Duration?
    public var keepNewest: Int?
    public var owners: [OwnerSpec]           // bundle IDs or process names
    public var requiresSibling: [String]     // e.g. Cargo.toml beside target/
    public var excludeNames: Set<String>
}

public enum Action: Sendable, Hashable { case trash, ownerCommand(OwnerCommandSpec), none }

public struct Rule: Sendable, Identifiable, Hashable {
    public let id: String                    // "dev.xcodeDerivedData"
    public let category: Category
    public let tier: Tier
    public let roots: [RootSpec]
    public let match: MatchSpec
    public let depth: Int
    public let guards: Guards
    public let access: Access
    public let action: Action
    public let title: LocalizedStringResource
    public let explain: LocalizedStringResource
}

public struct Finding: Sendable, Identifiable {
    public let id: UUID
    public let ruleID: String
    public let url: URL
    public let device: UInt64
    public let fileID: UInt64
    public let allocatedBytes: Int64
    public let newestModification: Date?
    public let isDirectory: Bool
}

public struct PathPolicy: Sendable {           // pure decisions on resolved paths
    public func isProtected(_ resolved: URL, home: URL) -> ProtectedReason?
    public func isInside(_ resolved: URL, roots: [URL]) -> Bool
    public func isRoot(_ resolved: URL, roots: [URL]) -> Bool
}

public enum Catalog { public static let all: [Rule] }   // built from Catalog/*.swift
```

`ByteFormatter` wraps `ByteCountFormatStyle` (`.file`) so all sizes read the
same as Finder.

## 3. CleanerScanner

| Type | Job |
|---|---|
| `BulkWalker` | Reads one directory with `getattrlistbulk` into a reusable buffer; yields `RawEntry` (name bytes, type, device, fileID, flags, link count, alloc size, mod date). Opens children with `openat` relative to the parent fd. Never follows links (`O_NOFOLLOW`). |
| `WalkPool` | Bounded worker pool over a work queue of directory fds/paths; stops on device change; cooperative cancellation. |
| `SizeAccumulator` | Per-root and per-folder totals to a depth; hard-link set only for `linkCount > 1`; top-N heap. |
| `ScanEngine` (actor) | Expands rules, runs walks, applies `Matcher`, emits `ScanEvent`s. |
| `VolumeInfo` | `URLResourceValues` capacities, `statfs`, `ATTR_VOL_SPACEUSED`. |
| `Snapshots` | Runs `/usr/bin/tmutil listlocalsnapshots /` (read-only), parses dates. |
| `Simulators` | Runs `/usr/bin/xcrun simctl list devices --json` and `runtime list --json`. |
| `AccessProbe` | Tri-state FDA from several protected reads; per-path `EPERM` collection. |
| `ReadOnlyCommand` | Shared runner for read-only commands (absolute path, argv, scrubbed env, timeout). |

`FileManager.enumerator` is the fallback walker if spike S1 shows
`getattrlistbulk` is not worth its complexity.

## 4. CleanerActions

```swift
public protocol RunningAppsProvider: Sendable {      // app layer wraps NSRunningApplication
    func state(of owner: OwnerSpec) async -> OwnerState  // .running, .notRunning, .unknown
}
public protocol OpenFilesProvider: Sendable {         // proc_listpidspath
    func hasOpenFiles(under url: URL) async -> Bool?  // nil = unknown → keep
}

public enum Verdict: Sendable { case allow, deny(SkipReason) }
public enum SkipReason: Sendable, Codable {
    case outsideRoots, protectedPath, isRoot, symlinkAncestor, changedSinceScan,
         ownerOpen(String), ownerUnknown, openFiles, openFilesUnknown,
         macOSProtected, insideBundle, tooNew, keepNewest, needsAccess, userExcluded,
         infoRule, probeFailed
}

public struct SafetyGate: Sendable {
    public func authorize(_ f: Finding, rule: Rule, context: GateContext) async -> Verdict
}

public enum DeleteMode: Sendable, Codable { case trash, permanent }
public struct Cleaner: Sendable {
    public func run(_ plan: CleanPlan, progress: @Sendable (CleanProgress) -> Void) async -> CleanReport
    public func preview(_ plan: CleanPlan) async -> [Finding.ID: Verdict]   // same gate
}
```

Gate order (cheapest first, all must pass): rule tier is not Info → user
exclusion → resolve real path of the parent → inside roots → not a root →
protected list → no symlinked ancestor → not inside a code bundle → flags →
`(device, fileID)` unchanged → age and keep-newest still hold → owner closed →
no open files.

`TrashExecutor` uses `FileManager.trashItem(at:resultingItemURL:)` or
`NSWorkspace.recycle` (chosen by spike S3) and records the resulting URL.
`History` is a JSON Lines file in
`~/Library/Application Support/TruongCleaner/history.jsonl`, written with
atomic appends; one `begin` and one `finish` record per clean, one record per item.

## 5. App layer

- `AppModel` (`@Observable @MainActor`): selected page, volume info, last scan,
  access state, settings. Injected through `.environment`.
- One model per page (`OverviewModel`, `SmartCleanModel`, …). Models call the
  kit and hold only display data.
- `Platform/RunningApps.swift` implements `RunningAppsProvider` with
  `NSWorkspace.shared.runningApplications` plus `proc_listallpids` for CLI
  owners (xcodebuild, docker, gradle).
- Settings are `@AppStorage` for simple values and a JSON file for exclusions.

## 6. Error handling

- Kit functions throw typed errors (`ScanError`, `CleanError`) with a
  user-facing message and a debug detail.
- Paths in logs use `privacy: .private`.
- Nothing crashes on a bad file: every per-item error becomes an outcome.

## 7. Testing strategy

| Level | What | Where |
|---|---|---|
| Unit | Matcher, PathPolicy, catalog well-formedness (unique IDs, Info has no action, roots absolute after expansion), formatting | `CleanerCoreTests` |
| Fixture | Walker totals vs a known tree (files, hard links, symlinks, nested, unreadable dir via `chmod 000`), cancellation, device boundary (mounted disk image, optional) | `CleanerScannerTests` |
| Safety | One test per `safety.md` rule 1–16, plus one per incident in `RESEARCH.md` §3.3 | `CleanerActionsTests/SafetyRulesTests.swift` |
| Rule | Five obligations per rule (`RULE_CATALOG.md` §5), parameterized over the catalog with a fixture home | `CleanerActionsTests/RuleObligationTests.swift` |
| Lint | `scripts/check-deletion-sites.sh` fails if a deleting API appears outside `CleanerActions` | CI `logic` job |
| Bench | `tcbench` numbers into `docs/EVIDENCE.md` | Manual, per wave |
| Hand | Ian's checks marked ✋ in `PLAN.md` | Per wave |

Fixture homes: tests pass a `home` URL into the catalog expansion, so every
`~` rule points into `build/test-fixtures/<uuid>/home/`.
