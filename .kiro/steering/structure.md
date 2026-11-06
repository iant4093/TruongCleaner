---
inclusion: always
---

# Structure

```text
.
├── src/
│   └── TruongCleaner/              App target (SwiftUI)
│       ├── App/                    TruongCleanerApp.swift, AppModel, commands, Settings scene
│       ├── Pages/                  Overview/, SmartClean/, SystemData/, Developer/,
│       │                           LargeFiles/, SpaceLens/, Trash/, History/, Settings/
│       ├── Components/             IconTile, StorageBar, CleanBar, SizeText, NeedsAccessRow
│       ├── Platform/               NSWorkspace/NSOpenPanel wrappers, running-app provider
│       └── Resources/              Assets.xcassets, AppIcon.icon, Info.plist, Localizable.xcstrings
├── Packages/
│   └── CleanerKit/
│       ├── Package.swift           tools 6.4, macOS 26, Swift 6 mode, warnings as errors
│       ├── Sources/
│       │   ├── CleanerCore/        Models/, Catalog/ (one file per category), Policy/, Format/
│       │   ├── CleanerScanner/     BulkWalker, SizeAccumulator, VolumeInfo, Snapshots,
│       │   │                       Simulators, AccessProbe, ScanEngine
│       │   ├── CleanerActions/     SafetyGate, Liveness, TrashExecutor, OwnerCommand,
│       │   │                       History, Undo
│       │   └── tcbench/            Dev-only benchmark executable (not in the app)
│       └── Tests/
│           ├── CleanerCoreTests/
│           ├── CleanerScannerTests/
│           ├── CleanerActionsTests/
│           └── Fixtures/           FixtureTree builder helpers
├── TruongCleaner.xcodeproj/        File-system synchronized groups; shared scheme
├── scripts/                        lint, test, build, package, install.sh, check-workflows,
│                                   bench, clean; hooks/ (orchestrator-owned)
├── spikes/                         Wave 0 experiments; never imported
├── docs/                           PLAN, RESEARCH, RULE_CATALOG, UI, EVIDENCE, HANDOFF,
│                                   briefs/, research/, evidence/, screenshots/
├── .kiro/                          agents, steering, hooks, specs (always tracked)
├── .github/                        ci.yml, dependabot.yml, actionlint.yaml
├── .swiftlint.yml
├── AGENTS.md
├── LICENSE
└── README.md
```

## Rules

- The Xcode project uses file-system synchronized groups (objectVersion 77),
  so adding a Swift file under `src/TruongCleaner/` needs no `project.pbxproj`
  edit. Only build settings, targets or package links change the project file.
- The app target links the `CleanerKit` products from the local package.
- Generated output goes to `build/` (git-ignored). Nothing writes to the repo
  root or to `~/Library/Developer/Xcode/DerivedData` from scripts: always pass
  `-derivedDataPath build/...`.
- New top-level folders need orchestrator approval.
