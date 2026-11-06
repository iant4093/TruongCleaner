# Brief <task-id>: <short title>

You are builder-sonnet. Implement exactly this brief. Read `AGENTS.md` and the
steering files first; `safety.md` and `tech.md` always apply.

## Goal

<One paragraph: what exists when you are done and why.>

## Requirements

<REQ-IDs from `.kiro/specs/truongcleaner/requirements.md`, each with one line on how it is met.>

## Context

<Design sections, catalog rows, UI sections, spike results, or earlier tasks this builds on.>

## Files

| Allowed to create or edit | Read-only references |
|---|---|
| `<paths or globs>` | `<paths>` |

Anything else is out of bounds. If you need another file changed, stop and say so in your report.

## Tests required

<Test names or behaviors, with fixture shapes. Parameterized where the brief covers a table.>

## Commands to run before finishing

```bash
bash scripts/lint.sh
bash scripts/test.sh package
bash scripts/build.sh debug
```

## Stop condition

<Exact definition of done.>

## Out of scope

<What not to do, even if tempting.>

## Report format

1. Files changed (paths).
2. Tests added (names) and their result.
3. Every command run, with exit code.
4. Deviations from this brief and why.
5. Open questions.
