---
inclusion: always
---

# Tech rules

## Stack

- Swift 6.4, Swift 6 language mode, `-strict-concurrency=complete`, warnings
  as errors (`SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`, `.treatAllWarnings(as: .error)`
  in the package). Xcode 27.0.
- macOS deployment target **26.0**, `ARCHS = arm64`. Never call an API newer
  than 26.0 without `if #available(macOS 27, *)`.
- SwiftUI + `@Observable`. View models are `@Observable @MainActor final class`,
  held in `@State`. Declare `@State` properties without a default when `init`
  assigns them (Xcode 27 `@State` macro rule).
- AppKit only for: `NSWorkspace.icon(forFile:)`, `NSWorkspace.recycle`,
  `NSWorkspace.activateFileViewerSelecting`, `NSWorkspace.open`, `NSOpenPanel`,
  `NSRunningApplication`. Nothing else without approval.
- **Zero third-party dependencies**, runtime or build. System frameworks only.
  No CocoaPods, no Carthage, no SwiftPM remote packages.
- Not sandboxed. Hardened Runtime off while ad-hoc signed.

## Module boundaries

- `CleanerCore`: pure Swift + Foundation value types. No file I/O, no
  `Process`, no AppKit. Rules, models, path policy logic, formatting.
- `CleanerScanner`: reads the file system (Darwin `getattrlistbulk`,
  `statfs`, `getattrlist`) and runs read-only commands (`tmutil listlocalsnapshots`,
  `xcrun simctl list --json`). Never deletes.
- `CleanerActions`: the **only** module that changes the disk. Entry point
  `SafetyGate` then `Executor`. Owner commands run here.
- App target: views and view models only. It calls CleanerKit; it never
  touches files directly except opening/revealing them.
- Tests import modules with `@testable import`; nothing in `Sources/` imports tests.

## Concurrency

- Scanning, sizing and deletion never run on the main actor. Mark heavy entry
  points `@concurrent` or put them on an actor. Under MainActor default
  isolation, a plain `nonisolated async` function can still run on main.
- Bounded parallelism: a worker pool sized `min(8, activeProcessorCount)`;
  never a task per file.
- Progress goes out through `AsyncStream`, throttled to ≤ 10 updates/s.
- Cancellation: check `Task.isCancelled` per directory batch; stop within 100 ms.
- All public types crossing actors are `Sendable`.

## File system

- Use allocated size (`ATTR_FILE_ALLOCSIZE` / `totalFileAllocatedSize`), not
  logical size. Count hard links once by `(device, fileID)`.
- Never follow symlinks when scanning or deleting. Never cross a device ID.
- Scan `/System/Volumes/Data` paths, not `/`, for whole-volume work.
- Treat `EPERM`/`EACCES` as "needs access", never as size 0.
- Paths are `URL`s or `FilePath`; never build paths by string concatenation.

## Processes

- Run owner commands with `Process`, an absolute executable path from a fixed
  list (`/usr/bin/xcrun`, `/usr/bin/tmutil`, `/opt/homebrew/bin/brew`, …), an
  argv array, a scrubbed environment (`PATH=/usr/bin:/bin`, `HOME`, `LANG`),
  and a timeout. Never a shell, never a string built from input.
- Never trust environment variables or command output as delete targets.

## Performance

- Budgets in `docs/PLAN.md` §5. No allocation per file in the walker beyond the
  name bytes; reuse the `getattrlistbulk` buffer per worker.
- No timers or polling while idle.
- Cache `NSWorkspace` icons by path.

## Testing

- Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`,
  parameterized `arguments:`) in `Packages/CleanerKit/Tests/`.
- Tests build fixture trees under `build/test-fixtures/<uuid>/` (path from
  `TC_FIXTURE_ROOT` or the package's `build/` folder) and remove them after.
  **No test reads or writes the real home folder, `~/Library`, or `/Library`.**
- Every rule in `docs/RULE_CATALOG.md` has the five test obligations in its §5.
- Every rule in `.kiro/steering/safety.md` has a test that would fail without it.
- Liveness checks (running apps, open files) are behind protocols so tests can
  inject fakes.

## Style

- SwiftLint config in `.swiftlint.yml` (correctness rules, like TruongCam).
- No force unwraps or `try!` outside tests. No `print` in shipping code; use
  `Logger` (os) with privacy markers for paths.
- Doc comments on every public type and function in CleanerKit.
