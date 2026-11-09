---
inclusion: always
---

# Safety rules (never break)

A cleaner that deletes the wrong file is worse than no cleaner. These rules
come from real data-loss incidents in other tools (`docs/RESEARCH.md` §3.3).
Each one has a test in `CleanerActionsTests/SafetyRulesTests.swift` that fails
if the rule is removed. Reviews reject any change that weakens one.

## For the app

1. **One door.** Only `CleanerActions.SafetyGate` may approve a deletion, and
   only `CleanerActions` executors may perform one. No other code calls
   `FileManager.removeItem`, `trashItem`, `unlink`, `rmdir`, `NSWorkspace.recycle`
   or runs `rm`.
2. **Allow-list.** An item is eligible only if a rule in `docs/RULE_CATALOG.md`
   produced it and it lies inside that rule's roots after resolving `..`
   and the parent's real path.
3. **Protected list wins.** The global protected list in `RULE_CATALOG.md` §3
   and the user's exclusions are checked last and always win.
4. **Children only.** Never delete a rule's root folder, `~`, `~/Library`, or
   any folder named in the protected list. Delete what is inside.
5. **No symlinks.** Never follow a symlink while scanning or deleting. A
   symlinked item is deleted as a link only if the rule allows it; its target
   is never touched. A symlinked ancestor makes the item ineligible.
6. **Re-check at the door.** Just before acting on each item, re-read its
   `(device, fileID)` and compare with the scan. Changed = skip.
7. **Owner closed.** If a rule names an owner app or process and it is running,
   skip the item and say so. If we cannot tell, skip.
8. **Open files.** Skip items that a process has open (`proc_listpidspath`).
   If the check fails, skip.
9. **Unknown means keep.** Timeouts, unreadable dates, failed probes, parse
   errors and unknown app state never lead to deletion. Never cache a negative.
10. **macOS protection.** Skip items with `SF_RESTRICTED`, `SF_NOUNLINK`,
    `UF_IMMUTABLE` or `SF_IMMUTABLE` flags, and anything under the protected
    system paths. Report them as "Protected by macOS", not as errors.
11. **Trash by default.** The default action moves items to the Trash and
    writes a history entry before and after. Permanent delete needs an explicit
    per-clean choice and a second confirmation.
12. **Say exactly what happened.** The result lists each item as moved,
    deleted, skipped (with reason) or failed. Never report a move that did not
    happen.
13. **No bundle edits.** Never modify anything inside a `.app`, `.framework`
    or other code bundle. Deleting an entire installer app (`installers.macOS`)
    is the only bundle-level action.
14. **Owner commands are fixed.** Only the argv lists in the catalog, absolute
    executable paths, scrubbed environment, timeout. Never a shell.
15. **Dry run = real run.** Preview and clean use the same `SafetyGate`
    checks. The only difference is the final executor call.
16. **Info rows never delete.** A rule with tier Info has no action.
16a. **Self-update exception.** `CleanerActions/Update/` may rename the running
    TruongCleaner bundle, move a verified new bundle into its place, and later move
    old `.TruongCleaner-old-*.app` bundles (bundle ID checked) to the Trash. These
    paths touch only TruongCleaner's own bundle and do not go through `SafetyGate`
    (approved 2026-11-09, task 8.2).

## For agents working in this repo

17. **Never clean the developer's Mac.** Builders and the orchestrator must not
    run the app's clean actions, `rm -rf`, `trash`, `tmutil delete*`,
    `tmutil thinlocalsnapshots`, `xcrun simctl delete`, `xcrun simctl erase`,
    `xcrun simctl runtime delete`, `brew cleanup`, `docker * prune`,
    `mdutil -E`, `pnpm store prune`, `go clean`, `npm cache clean` or any
    delete outside `build/` and `spikes/*/out/`. The `safety-guard` hook blocks
    these. Tests use fixture trees only.
18. Reading the real file system for spikes and benchmarks (`tcbench`, `du`)
    is allowed. Writing to it outside the repo is not.
19. A hand test of real cleaning is done by Ian, on items he chooses, after
    the orchestrator's review.
