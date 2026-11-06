---
inclusion: always
---

# Agent roles and handoff

| Agent | Model | Owns |
|---|---|---|
| Orchestrator (`architect-opus`, or the Kiro Crew session) | `claude-opus-5.5` | `.kiro/`, `docs/` (except `docs/screenshots/`), `README.md`, `AGENTS.md`, `LICENSE`, `.github/`, `.gitignore`, `.swiftlint.yml`, `scripts/hooks/`, git: commits, pushes, tags, releases |
| `builder-sonnet` | `claude-sonnet-5.5` | `src/`, `Packages/`, `TruongCleaner.xcodeproj/`, `scripts/` (not `scripts/hooks/`), `spikes/`, `docs/screenshots/` |

## Handoff protocol

1. The orchestrator writes `docs/briefs/<task-id>.md` from
   `docs/briefs/TEMPLATE.md`: task ID from `tasks.md`, goal, requirement IDs,
   files allowed, files read-only, tests required, commands to run, stop
   condition, out of scope.
2. It dispatches:
   `kiro-cli chat --v3 --agent builder-sonnet --no-interactive --trust-tools=fs_read,fs_write,shell,execute_bash,grep,glob "$(cat docs/briefs/<task-id>.md)"`
   `--v3` is needed for `.kiro/hooks` to run. Add `--trust-workspace` if spike
   S8 shows non-interactive runs skip hooks otherwise.
   Parallel dispatch only for briefs whose "files allowed" sets do not overlap
   and that do not both edit `project.pbxproj` or `Package.swift`.
3. The builder implements only the brief. Hooks build after writes and block
   the end of its turn until lint, package tests and the Debug build pass.
4. The builder ends with a report: files changed, tests added (names), every
   command run with its result, deviations from the brief, open questions.
5. The orchestrator reviews (checklist below), reruns
   `bash scripts/lint.sh && bash scripts/test.sh package && bash scripts/build.sh debug`,
   and records the result in `docs/EVIDENCE.md`.
6. Pass: mark the task `[x]` in `tasks.md`, commit with the task ID in the
   message. Fail: write `docs/briefs/<task-id>-fix<n>.md` naming each finding.

## Review checklist

- [ ] Only allowed files changed; no new dependency; no new top-level folder.
- [ ] Every requirement ID in the brief is met and tested.
- [ ] Safety: no deletion outside `CleanerActions`; no symlink following; protected list applied; "unknown means keep" holds; Info rules have no action.
- [ ] Concurrency: no file I/O or `Process` on the main actor; `Sendable` across actors; bounded parallelism; cancellation works.
- [ ] Performance: no per-file objects kept; buffers reused; progress throttled.
- [ ] Errors: `EPERM` becomes "needs access", not 0; user-visible text is plain.
- [ ] UI: standard components; glass only on controls; Reduce Transparency handled for custom glass; no API newer than macOS 26 without `#available`.
- [ ] Tests use fixture trees only; no test touches the real home folder.
- [ ] No force unwraps / `try!` / `print` in shipping code.

## Rules for both

- No new dependency, entitlement or top-level folder without a decision in `docs/PLAN.md`.
- The builder never commits, pushes, changes git config, or edits files it does not own. If a brief needs such a change, it says so in its report.
- A task is not done because the builder says so. It is done when the review passes.
- Neither agent runs real cleaning on this Mac (`safety.md` rule 17).
