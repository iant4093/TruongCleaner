---
inclusion: always
---

# Product: TruongCleaner

A small, fast, native macOS app that shows where disk space went and frees it
safely. It explains what Storage settings lumps into "System Data", cleans
what is safe to clean, and shows the Apple-approved fix for what no app may
touch. It looks like System Settings (glass sidebar, colored icon tiles,
grouped forms).

Owner: Ian Truong (`iant4093`). Repo: `iant4093/TruongCleaner`. Format
reference: `iant4093/TruongCam`.

## Users and goals

- A Mac user with a full disk opens the app, clicks Scan, and within seconds
  sees what uses space and what is safe to remove.
- A developer frees Xcode, simulator, package-manager and Docker space without
  breaking their tools.
- Nobody loses data. Cleaning moves items to the Trash by default and can be undone.

## Scope

v1.0: Overview, Smart Clean, System Data, Developer, Large & Old Files, Space
Lens, Trash, History, Settings. See `docs/PLAN.md` §3.

Later: App Uninstaller (Wave 6), privileged helper (needs Developer ID), menu
bar extra, Homebrew tap, duplicates.

Never: editing app bundles, touching iCloud/Photos/Mail stores/Messages
attachments/Keychains/AI-agent memory, asking to disable SIP, "memory
cleaning", fake alerts, telemetry.

## UX rules

- Looks native: standard SwiftUI components, system fonts and colors, glass on
  controls only. See `docs/UI.md`.
- Plain words. Each row says what it is and what happens if removed.
- Honest numbers: sizes are allocated bytes on disk; estimates say "about";
  after a clean, show the real change in free space.
- Every skipped item says why ("Slack is open", "Needs Full Disk Access").
- The app does nothing in the background unless the user starts it.
