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
