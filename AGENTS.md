# AGENTS.md

Instructions for any AI agent working in this repo (Kiro, Claude, Codex, or other).

## What this is

TruongCleaner: a native macOS disk cleaner. Swift 6.4, SwiftUI, macOS 26+,
arm64, zero third-party dependencies. It explains "System Data" and frees
space safely, with a System Settings look and Liquid Glass controls.

Status: **planning done, Wave 0 (spikes) next.** Nothing is built yet.

## Read first, in order

1. `docs/HANDOFF.md`: where the work stands and what to do next.
2. `.kiro/steering/safety.md`: rules that no change may break.
3. `.kiro/steering/agent-roles.md`: who owns which files and how tasks move.
4. `.kiro/steering/tech.md` and `structure.md`: stack and layout rules.
5. `.kiro/specs/truongcleaner/tasks.md`: the task list.
6. Your brief in `docs/briefs/<task-id>.md`, if you are a builder.

Background: `docs/PLAN.md` (decisions, waves, CI/CD), `docs/RESEARCH.md`
(stack and competitor findings), `docs/RULE_CATALOG.md` (what gets cleaned),
`docs/UI.md` (screens), `.kiro/specs/truongcleaner/requirements.md` and
`design.md`.

## Roles

| Role | Model | Does |
|---|---|---|
| Orchestrator / reviewer | Claude Opus 5.5 | Plans, writes briefs, reviews every change, owns docs, CI and git |
| Builder | Claude Sonnet 5.5 (`builder-sonnet`) | Implements one brief at a time with tests; never commits |

## Hard rules

- **Never clean or delete real data on this Mac.** Tests use fixture trees under `build/test-fixtures/`. See `safety.md` rule 17. A hook enforces it.
- All deletion goes through `CleanerActions.SafetyGate`. No exceptions.
- No third-party dependencies. No new top-level folders, entitlements or targets without the orchestrator.
- Swift 6 mode, strict concurrency, warnings as errors. No file I/O on the main actor.
- Builders edit only the files their brief allows and never touch `.kiro/`, `docs/*.md`, `README.md`, `AGENTS.md`, `.github/` or `scripts/hooks/`.
- Only the orchestrator commits and pushes. It may push to `main` (Ian, 2026-11-06).
- Never copy code from other cleaners. Mole, Lemon and Peel are GPL; Pearcleaner has a Commons Clause. Use the facts in `docs/research/`, written in our own code.
- Every number published (README, release notes) must come from `docs/EVIDENCE.md`.

## Commands (available from Wave 1)

```bash
bash scripts/lint.sh               # SwiftLint, pinned
bash scripts/test.sh package       # Swift Testing for CleanerKit
bash scripts/build.sh debug        # Debug app build into build/
bash scripts/build.sh all          # Debug + Release
bash scripts/package.sh            # ad-hoc sign, DMG, ZIP, checksums
bash scripts/check-deletion-sites.sh
bash scripts/clean.sh              # removes build/ only
```
