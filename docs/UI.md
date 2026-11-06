# TruongCleaner: UI specification

Goal: a user who opens TruongCleaner should think it came with macOS. It
should look and behave like System Settings on macOS 26/27: a glass sidebar
with colored icon tiles and a search field, grouped forms on the right, plain
language, and no custom chrome.

Spike S5 checks the prototype against a real System Settings screenshot
before Wave 1 locks the components.

---

## 1. Principles

1. **Standard components first.** `NavigationSplitView`, `List`, `Form`
   (`.formStyle(.grouped)`), `LabeledContent`, `Toggle`, `Picker`, `ProgressView`,
   `Table`, `.searchable`, `.inspector`, `.confirmationDialog`, `.sheet`.
   They adopt Liquid Glass and accessibility settings automatically.
2. **Glass on controls, not content.** Liquid Glass is for the toolbar, the
   floating clean bar and small overlay controls. Rows, lists and forms stay
   plain. Use `Glass.regular`; never `.clear` (no media backgrounds).
3. **No custom backgrounds** behind the sidebar, toolbar or split view.
4. **System fonts and colors only.** SF Pro via `.font(.title)`, `.headline`,
   `.body`, `.callout`, `.caption`; `.foregroundStyle(.secondary)` for detail
   text; semantic colors; accent color = system accent.
5. **Plain words.** "Caches", not "junk". Say what happens: "Moves 3.2 GB to
   the Trash". No scare text, no fake urgency.
6. **Honest numbers.** Sizes are "on disk". Estimates say "about". After a
   clean, show the real change in free space.

## 2. Window

| Property | Value |
|---|---|
| Scene | `WindowGroup` with one window; `Settings` scene for preferences (⌘,) |
| Default size | 900 × 620; minimum 760 × 520 |
| Toolbar | Unified, title = current page; trailing: Scan button (`.buttonStyle(.glassProminent)` while idle, Stop while scanning) |
| Sidebar | `NavigationSplitView` sidebar, width 215–260, `.searchable(placement: .sidebar, prompt: "Search")` |
| Detail | `Form` with `.formStyle(.grouped)`, or `List` / `Table` for results |
| Inspector | Optional `.inspector` for item details (path, size, dates, why it is safe) |

## 3. Sidebar

Rows are `Label { Text } icon: { IconTile(symbol:color:) }`.

| Section | Row | SF Symbol | Tile color |
|---|---|---|---|
| (top) | Overview | `internaldrive.fill` | gray |
| Clean | Smart Clean | `sparkles` | blue |
| Clean | System Data | `gearshape.2.fill` | gray |
| Clean | Developer | `hammer.fill` | indigo |
| Clean | Large & Old Files | `doc.text.magnifyingglass` | orange |
| Explore | Space Lens | `chart.pie.fill` | purple |
| Explore | Applications (Wave 6) | `square.grid.2x2.fill` | blue |
| Manage | Trash | `trash.fill` | gray |
| Manage | History | `clock.arrow.circlepath` | teal |

Each row shows a trailing size badge after a scan (`.badge(Text("12.4 GB"))`).
Symbols must exist in SF Symbols 7 (macOS 26 floor); check in the SF Symbols app.

### 3.1 Icon tile

There is no public API for System Settings' tiles. Draw one:

- 24 × 24 pt, `RoundedRectangle(cornerRadius: 6, style: .continuous)`.
- Fill: `color.gradient`.
- Symbol: white, 13 pt semibold, `.symbolRenderingMode(.monochrome)`.
- Tune size and radius against a System Settings screenshot in S5.

## 4. Pages

Every page starts like System Settings' top-level pages: a **header group**
with a 64 pt icon tile, a title (`.title2.bold()`), and one line of secondary
text. Then grouped sections.

### 4.1 Overview

```text
┌ [drive tile]  Macintosh HD                                     ┐
│               460.3 GB of 994.7 GB used · 534.4 GB available     │
│  ████████▓▓▓▓▓▒▒▒▒░░░░░░·························                │  ← Charts BarMark, stacked
│  ● Apps ● Documents ● Developer ● Caches ● iOS ● Snapshots ● Unexplained │
└──────────────────────────────────────────────────────────────────┘
Recommendations
  [sparkles] Smart Clean can free about 18.2 GB            [Review…]
  [hammer]   Xcode DerivedData uses 9.1 GB                 [Review…]
  [iphone]   2 iPhone backups use 41 GB                    [Review…]
Storage details
  Purgeable              12.0 GB      (i)
  Local snapshots        7 · size unknown   (i)
  Unexplained            23.4 GB      (i)
```

- The bar segments use system colors with labels underneath, like Storage settings.
- `(i)` opens a popover explaining the number and where it comes from.

### 4.2 Smart Clean

- Before a scan: header + "Scan" button (glass prominent) + what will be checked.
- During: a determinate `ProgressView` per category, live sizes, Stop.
- After: one `Section` per category. Each row: icon, name, `explain` text
  (secondary), size, checkbox (`Toggle` with `.toggleStyle(.checkbox)`).
  Disclosure shows items. Review rows are unchecked; Info rows have no checkbox.
- A **floating clean bar** at the bottom: `GlassEffectContainer` with a summary
  ("Move 18.2 GB to the Trash") and a `.glassProminent` "Clean" button.
- Confirmation: `.confirmationDialog` listing totals per category. Permanent
  delete needs a second explicit choice.
- After: result sheet with real free-space change, skipped items and reasons
  ("Slack is open"), "Free Space Now" (empties our items from Trash) and "Undo".

### 4.3 System Data

A grouped list. Each row: tile, name, size (or "Unknown"), tier label, and a
trailing action button: "Clean…", "Open Settings", "Copy Command", "Learn More".
The top shows how our total compares with "used" and the "Unexplained" remainder.

### 4.4 Developer

Sections: Xcode, Simulators (a `Table` of devices and runtimes with last-used
date), Package Managers, Docker, Project Folders (user adds folders with
`NSOpenPanel`; results grouped by project).

### 4.5 Large & Old Files

Controls row: folders, minimum size (`Picker`: 50 MB, 100 MB, 500 MB, 1 GB),
not opened in (30 d, 90 d, 1 y). Results in a sortable `Table` (Name, Kind,
Size, Last Opened, Location). Nothing pre-selected. Quick Look with Space.

### 4.6 Space Lens

A sunburst (`SectorMark` rings, or a custom `Canvas` if Charts is too slow for
large trees) for one chosen folder, with a breadcrumb path bar. Click to drill
down; hover shows name and size; context menu: Reveal in Finder, Quick Look,
Move to Trash (through the safety gate).

### 4.7 Trash and History

Trash: size, item count, "Empty TruongCleaner Items", "Empty Trash" (confirm).
History: a list of cleans (date, total, item count). Detail shows each item,
where it went, and "Put Back" while it is still in the Trash.

### 4.8 Settings (⌘,)

Tabs like a standard Settings window: General (delete mode, update check),
Exclusions (folder list with + / −), Rules (per-category on/off, ages),
Permissions (Full Disk Access status: granted / not granted / unknown, "Open
Privacy Settings", "Check Again").

## 5. Onboarding and Full Disk Access

- First launch: one sheet: what the app does, that it moves things to the Trash
  by default, and an optional Full Disk Access step with the deep link and a
  short animation of the toggle. "Skip for now" is always offered.
- Rows that hit `EPERM` show "Needs Full Disk Access" with a lock symbol and a button.
- Re-probe on `NSApplication.didBecomeActiveNotification`.

## 6. Accessibility

- Every control has a label; sizes are read as "12.4 gigabytes".
- Respect Reduce Transparency (swap custom glass for `.regularMaterial` or a
  solid fill), Increase Contrast, Reduce Motion (no animated sunburst
  transitions), and Dynamic Type sizes available on macOS.
- Full keyboard use: ⌘R scan, ⌘⌫ clean selected, Space Quick Look, ⌘F search.
- Test at both ends of the macOS 27 Liquid Glass slider and in Light and Dark mode.

## 7. App icon

Made in Icon Composer (layered `.icon` file) so it supports default, dark,
clear and tinted styles. Concept: a drive with a soft sparkle, in system blue.
