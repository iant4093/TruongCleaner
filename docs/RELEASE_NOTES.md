## TruongCleaner 1.0

A lightweight native Mac app that shows what is inside "System Data" and frees space safely.

**Install**

```bash
curl -fsSL https://github.com/iant4093/TruongCleaner/releases/latest/download/install.sh | sh
```

Or open the DMG, drag TruongCleaner to Applications, open it once, then choose
System Settings > Privacy & Security > Open Anyway. Later updates install from
Settings > General > Install Update.

**What it does**

- Overview with a real storage breakdown, purgeable space, snapshots and swap
- Smart Clean for caches, logs, browser and app caches
- System Data: every contributor, its size, and Apple's own fix
- Developer: Xcode, simulators, package caches, Docker, project build folders
- Applications: uninstall an app with the files it left behind
- Large & Old Files, Space Lens, Trash and History with Put Back
- Moves items to the Trash by default; skips anything in use and says why

**Good to know**

- Builds are ad-hoc signed, not notarized. macOS may ask for Full Disk Access again after an update.
- Full Disk Access is optional; without it, some rows say "Needs Full Disk Access".
- Smart Clean can take several seconds when `~/Library/Caches` holds about a million files; results appear section by section.
- Download only from this repository's Releases page.
