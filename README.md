<div align="center">

# TruongCleaner

A lightweight native Mac app that shows what is really inside "System Data" and frees space safely.

[Download latest DMG](https://github.com/iant4093/TruongCleaner/releases/latest/download/TruongCleaner.dmg) · [Releases](https://github.com/iant4093/TruongCleaner/releases) · [Build status](https://github.com/iant4093/TruongCleaner/actions) · [Report an issue](https://github.com/iant4093/TruongCleaner/issues)

![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-007AFF?logo=swift&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)
![Dependencies](https://img.shields.io/badge/runtime_dependencies-0-34C759)

</div>

---

> **Status: planning.** No build is available yet. The plan is in
> [`docs/PLAN.md`](docs/PLAN.md). This README follows the final layout; each
> section is filled in as its wave ships.

Storage settings on a Mac often show a huge "System Data" bar and little else.
TruongCleaner breaks it down: local Time Machine snapshots, the Spotlight index,
caches, logs, Xcode and simulator data, iOS backups, Docker images, Apple
Intelligence assets and more. It cleans what is safe to clean, moves items to
the Trash by default so you can undo, and shows Apple's own fix for the parts
no app may touch.

## Screenshots

_Coming with Wave 7._

## Features

**See where space went**

- Storage bar with a real breakdown, including purgeable space, snapshots and an "Unexplained" remainder
- System Data page: each contributor with its size, what it is, and how to reduce it
- Space Lens: a sunburst of any folder with drill-down

**Clean safely**

- Smart Clean for caches, logs, browser caches, app caches and old downloads
- Developer cleanup: Xcode, simulators, Swift packages, Homebrew, npm, Yarn, pnpm, pip, Cargo, Go, Gradle, Docker and project build folders
- Large & Old Files finder
- Moves items to the Trash by default, keeps a history, and can put items back
- Skips anything that is in use, recently changed, or owned by an open app, and says why

**Native and light**

- SwiftUI with the System Settings look and Liquid Glass controls
- No third-party dependencies, no telemetry, no background activity

## Install

```bash
curl -fsSL https://github.com/iant4093/TruongCleaner/releases/latest/download/install.sh | sh
```

The script downloads the latest build, checks it against `SHA256SUMS`, and
installs it in Applications. Download only from this repository's Releases page.

## Tech stack

| Area | Technologies |
|---|---|
| Interface | SwiftUI, Liquid Glass, Swift Charts, AppKit (icons, Trash, Finder) |
| Scanning | Darwin `getattrlistbulk`, APFS-aware sizing, Swift concurrency |
| Cleaning | One safety gate, Trash with history and undo, owner tools (`xcrun simctl`, `brew`, `docker`) |
| Quality | SwiftLint, Swift 6 strict concurrency, warnings as errors, Swift Testing, Xcode static analysis; CodeQL for workflows |
| Delivery | GitHub Actions, ad-hoc signed arm64 app, DMG and ZIP, SHA-256 checksums, build attestations |

## Build locally

Requires a Mac with **Xcode 27** and macOS 26 or later.

```bash
bash scripts/build.sh all      # Debug and Release
bash scripts/package.sh        # sign ad-hoc, DMG, ZIP, checksums
```

## Tests

```bash
bash scripts/lint.sh
bash scripts/test.sh package
```

Tests run against generated folder trees under `build/`. They never touch your
real files.

## CI and releases

Pull requests and pushes to `main` run workflow and secret checks, SwiftLint,
package tests, Debug and Release builds, Xcode static analysis, and packaging.
After all gates pass, pushes to `main` publish a GitHub Release with
`TruongCleaner.dmg`, `TruongCleaner.zip`, `install.sh`, `TruongCleaner.dSYM.zip`
and `SHA256SUMS`. Pull requests never publish.

## Repository layout

```text
.
├── src/TruongCleaner/      App: pages, components, platform glue
├── Packages/CleanerKit/    Core, scanner and safe-clean engine, with tests
├── TruongCleaner.xcodeproj/
├── scripts/                Lint, test, build, package and install
├── spikes/                 Experiments, never shipped
├── docs/                   Plan, research, rule catalog, UI spec, evidence
├── .kiro/                  Agent steering, specs, hooks and configs
├── .github/                CI/release workflow
├── AGENTS.md
└── README.md
```
