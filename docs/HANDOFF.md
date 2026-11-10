# Handoff

Last updated: 2026-11-09, after Wave 9 (v1.0 code review).

## State

**v1.0.0.** Four independent reviews (`docs/reviews/`) were fixed in tasks
9.1–9.5 (`docs/EVIDENCE.md`, "Wave 9"). Releases keep the `build-N` GitHub tag,
because the in-app updater reads that prefix; v1.0.0 is an annotated git tag on the
merge commit, with no separate GitHub release.

Every v1.0 feature is built, reviewed and released from `main`:
Overview, Smart Clean, System Data, Developer, Large & Old Files, Space Lens,
Applications (uninstaller, `docs/UNINSTALLER.md`), Trash, History, Settings
(exclusions, rules, delete mode, permissions, **in-app update install**),
onboarding, icon, README screenshots. Ian's first hand checks passed
(`docs/EVIDENCE.md`, "Ian's hand checks").

## How changes reach `main`

The host policy blocks `git push` to `main` from this session. Flow:

1. Commit on local `main`; `git branch -f integration main`.
2. `git push -v origin refs/heads/integration:refs/heads/integration` as its own
   command. It sometimes reports "Everything up-to-date" without updating the
   remote: confirm with `gh api repos/iant4093/TruongCleaner/branches/integration --jq .commit.sha`
   and repeat.
3. Open a PR to `main` (wait ~20 s after the push), check CI with
   `gh api "repos/iant4093/TruongCleaner/actions/runs?head_sha=<sha>"`, merge with
   `gh pr merge <n> --merge`, then `git merge origin/main`.

## Waiting on Ian (hand checks ✋)

1. **Update from Settings:** after the next release, open Settings > General and
   press Install Update. The app should relaunch on the new build. macOS may ask
   for Full Disk Access again.
2. **Applications:** pick an app you no longer need, check the leftovers list,
   uninstall it, then Put Back from History to confirm undo works. Tell me if user-installed
   apps show "Can't change the Applications folder" on your launch (the agent's
   sandboxed launch showed it; a normal launch should not).
3. **Look:** Smart Clean, Developer and System Data rows after the 8.1/8.3 polish.
4. **1.0.0 update:** from the installed build, Settings > Install Update should land on
   "TruongCleaner 1.0.0". Then try Quit (⌘Q) while a clean runs: the app should ask first.

## Known gaps (accepted for now)

- Smart Clean takes ~6.5–8 s on a 1 M-file `~/Library/Caches` (budget 5 s); results stream per section.
- Grouped `Form` on macOS 27 draws row dividers from the row edge, not the title.
- `trash.volumes` inert. A scan root of `/` covers only the System volume (REQ-SCAN-08 mapping to `/System/Volumes/Data` not done; no shipped rule uses `/`).
- Update authenticity rests on the GitHub account and HTTPS (SHA-256 file from the same release). Signing `SHA256SUMS` with Ed25519 waits on Ian (task 9.6).
- The owner check reads every process's argv, about 25 ms per item.
- Not hand-tested: the polite `osascript` quit in `install.sh`, and the Quit-during-clean alert.
- Ad-hoc signing: Full Disk Access may need re-granting after each update.

## Resume checklist

1. Read `AGENTS.md`, this file, `tasks.md`.
2. `git log --oneline | head`, `git status`, `git worktree list`.
3. Check `build/dispatch/*.done` for finished builders.
