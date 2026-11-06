# A. What open-source Mac cleaners clean: facts for the TruongCleaner rule catalog

Prepared 2026-11-06. Facts only (paths, categories, safety rules). No code was copied. Tool codes used in tables:

| Code | Tool |
|---|---|
| **M** | tw93/Mole (`mo clean`, plus `purge`, `installer`, `optimize` where noted) |
| **P** | mac-cleanup/mac-cleanup-py |
| **S** | mac-cleanup/mac-cleanup-sh (formerly fwartner/mac-cleanup) |
| **C** | guhcostan/mac-cleaner-cli |
| **U** | momenbasel/PureMac |
| **X** | iliyami/MacSai |

## 0. Method, scope and caveats

- Sources read: shallow clones of each repo at default-branch HEAD, plus `gh` API and issue search. Clone HEADs: Mole `6d1af75`, mac-cleanup-py `c8fbdb4`, mac-cleanup-sh `53b2c24`, mac-cleaner-cli `725f5e7`, PureMac `bc3580d`, MacSai `989eb05`.
- Mole is about 20k lines of clean modules. I extracted every `safe_clean`/`safe_sudo_*`/`safe_find_delete` call site (about 470) and read the helper functions that carry the rules (system, user, dev, app_caches, apps, brew, caches, snapshots, file_ops, app_protection, base, whitelist). Repetitive families are written as templates (for example the Chromium cache subfolders x browser roots). Targets that Mole builds from variables or command output (Go, Cargo, pnpm store, conda) are described by rule, not by literal path.
- "Default" column: **on** = runs in a normal run with no user action; **off** = ships protected or unselected; **review** = reported only, never deleted; **gated** = runs only when a condition holds.
- "sudo" column: **no** = runs as the user; **yes** = the tool escalates itself; **n/a** = owner command decides.
- Statements marked *(as read)* come from reading code and were not executed.
- Other workers' clones (Pearcleaner, lemon-cleaner, Clean-Me, PureMac, MacSai, etc.) sit in the shared `clones/` folder. I read PureMac and MacSai in place; that worker later removed its clones, so I finished the last checks for those two through the GitHub API. I did not read Pearcleaner, lemon-cleaner or Clean-Me.
- **Licence caution for TruongCleaner:** Mole is GPL-3.0 and Pearcleaner-class tools are often GPL too. Paths and categories are facts, but our catalog must be written independently from this document, not transcribed from Mole's source.
- **Not found in any tool:** `/private/var/vm/sleepimage` and swap files (zero hits in all six repos). The only "language pack" implementations are `.lproj` removal (C, U, X) and Mole `slim` (Intel slice removal). Details in section 9.

## 1. Repo metadata (as of 2026-11-06)

| Tool | URL | SPDX licence | Stars | Last commit (HEAD) / pushed_at | Language |
|---|---|---|---|---|---|
| M | https://github.com/tw93/Mole | GPL-3.0 | 74,118 | 2026-11-06 08:00 UTC / 2026-11-06 | Shell (bash 3.2 compatible) plus Go (`cmd/`, analyze/status) |
| P | https://github.com/mac-cleanup/mac-cleanup-py | Apache-2.0 | 2,375 | 2026-10-26 / 2026-10-30 | Python (3.11+) |
| S | https://github.com/mac-cleanup/mac-cleanup-sh (`fwartner/mac-cleanup` now redirects here) | MIT | 2,811 | 2023-05-21 / 2023-05-21 (**unmaintained for 3.5 years**) | Bash |
| C | https://github.com/guhcostan/mac-cleaner-cli | MIT | 2,023 | 2026-10-02 / 2026-10-29 | TypeScript (Node CLI, plus Electron menu-bar app in `desktop/`) |
| U | https://github.com/momenbasel/PureMac | MIT | 7,670 | 2026-11-06 04:46 UTC / 2026-11-06 | Swift (SwiftUI app plus Swift CLI in `cli/`) |
| X | https://github.com/iliyami/MacSai | BSD-3-Clause | 2,098 | 2026-11-06 22:00 UTC / 2026-11-06 | Swift (SwiftUI, SwiftPM) |

GitHub searches ("macos cleaner", "mac cleanup", "macos cache cleaner" and others, filtered to at least 1,000 stars) returned only these six plus Pearcleaner and similar app uninstallers handled by another worker. `2ykwang/mac-cleanup-go` (461 stars) was below the bar.

---

## 2. Mole (M)

### 2.1 Safety mechanisms

| Mechanism | What it does |
|---|---|
| Never root | `bin/clean.sh` exits if `EUID==0`. It requests admin only for the System section; `SYSTEM_CLEAN=true` only if a sudo session is already adopted or granted. Without it the System section is skipped and a hint is printed. |
| Dry-run | `mo clean --dry-run` / `-n` (`MOLE_DRY_RUN=1`). Writes a preview list to `~/.config/mole/clean-list.txt`. The dry-run runs the same eligibility predicates as the real run, including the final-sink checks. |
| Whitelist | `~/.config/mole/whitelist` (edited with `mo clean --whitelist`). Every delete funnels through `safe_remove`, which honours it. If the file cannot be read, `clean`, `purge` and `optimize` stop. |
| Default whitelist (shipped "off") | `~/Library/Caches/ms-playwright*`, `~/.gradle/caches/*`, `~/.gradle/daemon/*`, `~/.ollama/models/*`, Surge cache and data, renv cache, `~/Library/Caches/JetBrains*`, `com.jetbrains.toolbox*`, `tealdeer/tldr-pages`, `~/Library/Application Support/JetBrains*`, `~/Library/Caches/com.apple.finder`, `~/Library/Mobile Documents*`, and the `FINDER_METADATA` sentinel (so `.DS_Store` cleanup is off). These are replaceable by the user. |
| Hard safety whitelist (always merged) | `FINDER_METADATA`, `com.apple.FontRegistry*`, `com.apple.spotlight*`/`Spotlight*`, `CloudKit*`, `~/Library/Caches/kitty`, `pypoetry/virtualenvs*`, `org.R-project.R/R/renv/*`, `pnpm/dlx*`, `llama.cpp`. Reasons in comments: font/search/iCloud breakage, live interpreters, running `pnpm dlx` commands, multi-GB model weights. |
| Delete semantics | `clean`, `purge`, `installer` delete **permanently** (`rm -rf` after validation). `uninstall`, `analyze`, `slim` move to Trash. README and SECURITY_AUDIT (M01) state there is no general undo for `clean`. Trash is emptied with direct deletion, not Finder, because Finder's "empty Trash" warning dialog blocked runs. Volume Trashes (`/Volumes/*/.Trashes`) are not emptied. |
| Operation log | `~/Library/Logs/mole/operations.log` (`mo history`; `MO_NO_OPLOG=1` disables). Mole's own log dir is on the protected list. |
| Path validation | Must be absolute, non-empty, no `..` component, no control characters. Symlink leaf checked. **Ancestor-symlink guard:** the parent is canonicalised and the deny predicates re-run on the resolved path. |
| Critical deny list | `/`, `/bin`, `/sbin`, `/usr` (but `/usr/local/*` and `/opt/homebrew/*` children are deletable), `/System`, `/Library/Apple`, `/Library/Extensions`, `/Library/Keychains`, `/Library/Application Support` (root), `/Applications` (root), `/Applications/Finder.app`, `/Applications/Safari.app`, `/Volumes`, `/Users`, `/Users/Shared`, `/Users/<name>` (home root itself), `/etc`, `/var/db`, `/private/var/db`, `/private/var/root`, `/private/var/audit`, `/private/var/folders` (root), `/private/tmp`, `/private/var/tmp` (roots). Also checked by same-inode comparison to defeat case aliases (`/SYSTEM`) on case-insensitive APFS. |
| Explicit allow inside `/private` | Only `/private/tmp/*`, `/private/var/tmp/*`, `/private/var/log*`, `/private/var/folders/*`, `/private/var/db/{diagnostics,DiagnosticPipeline,powerlog,reportmemoryexception}`, `/private/var/db/receipts/*.bom\|*.plist`. One exception is also allowed: `/System/Library/Caches/com.apple.coresymbolicationd/data`. |
| SIP | **No explicit SIP/rootless/chflags check** in `lib/` or `bin/` (grep found only a `csrutil status` call in the updater). SIP safety comes entirely from the deny list plus an allow list of known-safe roots. |
| Protected path policy (`should_protect_path`) | Blocks System Settings/Control Center/Finder/Dock caches and containers, Notes, CoreAudio caches (`*com.apple.coreaudio*`, caused audio loss on Intel), `~/Library/Mobile Documents*` (**iCloud Drive**), `~/Library/{Accounts,Keychains,Mail,Calendars,Contacts}`, wallpaper/aerial assets (`com.apple.idleassetsd`, `com.apple.wallpaper`), Bluetooth/Wi-Fi ByHost prefs, NetworkExtension prefs, audio plug-in and licence-bearing vendor dirs (iZotope, Native Instruments, Avid, FabFilter, PACE, LaserSoft), Adobe caches, `ms-playwright`, HomeKit/FamilyCircle/Shortcuts caches, Google ID/Clearcut stores, OrbStack, EDR agents (CrowdStrike etc.), Codex/Claude-class AI app state (sessions, auth, history, sqlite), plus a very large `DATA_PROTECTED_BUNDLES` list (password managers, IDEs, VPN/proxy clients, DB clients, note apps, cloud sync clients, and so on). Container `Data/Library/Caches/*` and `Data/tmp/*` are explicitly let through. |
| Photos | No cleanup target touches Photos libraries. `com.apple.Photos` is in the protected bundle list. Only `~/Library/Caches/com.apple.photoanalysisd` is cleaned. Photos library search-index bloat is an open feature request (#1655), not implemented. |
| Mail | `~/Library/Mail` is protected. Only `Mail Downloads` (attachment copies) and `~/Library/Caches/com.apple.mail/*` are cleaned. Mail must not be running. Mail Downloads rule: folder older than 30 days, size threshold 5120 KB, and neither folder nor file modified after Mail created it (so edited or saved-beside copies are kept). |
| Messages | "Do not touch Messages attachments": only `StickerCache` and `Caches/Previews/{Attachments,StickerCache}`. |
| Running apps | Process and handle gates: per-app owner process check (running or unknown means keep); `lsof` open-handle probe on the exact path at the final deletion boundary; SQLite family in-use check (fail closed if lsof cannot answer); per-browser running checks; Application Support caches skipped if the app is running; Xcode DerivedData skipped unless a conclusive "no Xcode/xcodebuild" result; CoreSimulator work skipped if a simulator is booted or `simctl` is mid-setup; Time Machine ops skipped if a backup is running **or status unknown**. `clean` does not quit or kill user apps to reach their caches; it skips them. (The one exception is terminating *leaked automation browsers* it can prove are orphaned, matched by PID plus start time.) |
| TOCTOU | Parent and target inode identities are captured at discovery and re-verified at the delete sink; `safe_clean_guarded` re-asks a guard callback after sizing and immediately before each remove. Redirected roots (symlinked `~/Library/Logs`, `DENO_DIR`, `~/.gradle`) are refused. |
| Time budgets | System section 120 s total; per-probe timeouts 2/3/5/10/20/30 s (`MOLE_TIMEOUT_*`). A timeout means "keep", never "delete". |
| Fail-closed theme | Unknown state means skip. Examples: unreadable Software Update plist means keep installers; unreadable mtime means keep Time Machine backup; mdfind timeout means treat app as installed. |

**Age and size thresholds** (`lib/core/base.sh` plus call sites):

| Constant | Value | Used for |
|---|---|---|
| `MOLE_TEMP_FILE_AGE_DAYS` | 7 | `/Library/Caches` `*.cache`/`*.tmp`; idleassetsd `CFNetworkDownload_*.tmp` |
| `MOLE_LOG_AGE_DAYS` | 7 | `/Library/Caches` `*.log`, `/private/var/log`, Adobe logs, diagnostics, powerlog, cursor-agent logs |
| `MOLE_CRASH_REPORT_AGE_DAYS` | 7 | `/Library/Logs/DiagnosticReports` |
| `MOLE_SAVED_STATE_AGE_DAYS` | 30 | `optimize` task only (`.savedState` older than 30 d). `clean` removes `~/Library/Saved Application State/*` with no age filter. |
| `MOLE_ORPHAN_AGE_DAYS` | 30 | orphaned app data (also needs "not installed", see 2.4) |
| `MOLE_MAIL_AGE_DAYS` / `MOLE_MAIL_DOWNLOADS_MIN_KB` | 30 / 5120 | Mail Downloads |
| `MOLE_GPU_CACHE_AGE_DAYS` | 1 | Metal/GPU cache dirs: no file modified within 1 day |
| `MOLE_TM_BACKUP_SAFE_HOURS` | 48 | incomplete Time Machine backups |
| (inline) | 14 d | `/Applications/Install macOS*.app` |
| (inline) | 30 d | `/private/var/db/reportmemoryexception/MemoryLimitViolations`, `~/Library/Application Support/CrashReporter` |
| (inline) | >60 min | Handoff shared-pasteboard cache |
| (inline) | 7 d (`until=168h`) | `docker builder prune` |
| (inline) | `--prune=30` and 7-day stamp | `brew cleanup` runs at most once per 7 days |
| `MOLE_XCODE_DEVICE_SUPPORT_KEEP` | 2 | keep the 2 newest DeviceSupport dirs per platform |
| `MOLE_JETBRAINS_TOOLBOX_KEEP` | 1 | keep 1 previous IDE build in Toolbox |
| (inline) | 100 items | caches with more than 100 top-level entries are bulk-removed without per-item sizing |

### 2.2 `mo clean` targets by section (execution order)

Sections run in this order: External volume (opt-in `--external`), System, User essentials, App caches, Browsers, Cloud & Office, Developer tools, Apps & utilities, Virtualization, Application Support, App leftovers, Apple Silicon updates, Device backups & firmware, Time Machine, Large files (review), Project artifacts (hints).

#### System (`clean_deep_system`, **sudo**, default on only when a sudo session exists)

| Category | Path / command | sudo | Default | Safety notes |
|---|---|---|---|---|
| System caches | `/Library/Caches` files matching `*.cache`, `*.tmp`, `*.log`, age > 7 d, depth <= 5 | yes | on (sudo) | Files only; not directories. |
| Crash reports | `/Library/Logs/DiagnosticReports/*` files > 7 d, depth 1 | yes | on (sudo) | |
| System logs | `/private/var/log` `*.log` (plus `*.gz`, `*.asl`) > 7 d, depth <= 3 | yes | on (sudo) | |
| 3rd-party logs | `/Library/Logs/Adobe`, `/Library/Logs/CreativeCloud`, `/Library/Logs/adobegc.log` > 7 d | yes | on (sudo) | |
| Installers | `/Applications/Install macOS*.app` | yes | gated | Must be bundle `com.apple.InstallAssistant` (or seed suffix) with a valid Apple code signature (`codesign --verify --ignore-resources`); age >= 14 d; not running; not the current major macOS version; **no pending/unknown Software Update** (fail-closed); identity re-checked after sizing. Origin: removing staged update payloads on a macOS 27 beta once left a Mac unbootable (code comment, no issue number found). |
| Software Update staging | `/Library/Updates`, `/macOS Install Data` | n/a | **never** | Explicitly kept; owned by Software Update. |
| Browser code-signing clones | `$(getconf DARWIN_USER_DIR)/../X/<id>.code_sign_clone/code_sign_clone.XXXXXX` for Chrome (stable/beta/dev/canary), Chromium, Helium, Brave (+Beta/Nightly/Origin variants), Edge, ego lite | no | gated | Per-user only; requires all matching browser processes idle; exactly one known app bundle inside; sizes unknown (APFS shared extents). Reported cases: 112 idle Brave clones, 2.2 GB for Edge. |
| Icon services | `/Library/Caches/com.apple.iconservices.store` | yes | on (sudo) | |
| GPU/Metal caches | `/private/var/folders/*/*/C/*/com.apple.{gpuarchiver,metal,metalfe}` | yes | gated | Only if no contained file modified in the last 1 day; only the `C/` shard (never `T/`); skips EDR agent bundle ids (tamper detection reports as malware). |
| Aborted Aerial downloads | idleassetsd temp dir under root's `/private/var/folders` tree: `CFNetworkDownload_*.tmp` > 7 d | yes | on (sudo) | Origin: hundreds of GB of stuck ~1 GB tmp files (#1253). |
| Diagnostics DBs | `/private/var/db/diagnostics/*`, `/private/var/db/DiagnosticPipeline/*` files > 7 d | yes | on (sudo) | |
| Power telemetry | `/private/var/db/powerlog/*` files > 7 d | yes | on (sudo) | **Active powerlog database is never deleted** (a KeepAlive daemon reopens it). A >10 GiB notice only warns (#1283). |
| Memory reports | `/private/var/db/reportmemoryexception/MemoryLimitViolations/*` > 30 d | yes | on (sudo) | |
| Xcode docs index | `/Library/Developer/Xcode/DocumentationCache/DeveloperDocumentation*.index` | yes | gated | Keeps the newest index; removes older ones. |
| CoreSimulator system cache | `/Library/Developer/CoreSimulator/Caches/*` | yes | gated | Skipped when Xcode/Simulator/xcodebuild/xctest/simctl processes or a booted device are present. |
| Generic temp | `/private/tmp`, `/private/var/tmp` | n/a | **never** | Comment: age and bounded scans cannot prove third-party runtime state is disposable. |
| Local snapshots | `tmutil listlocalsnapshots /` | no | **review** | Counts and names only; Time Machine row shown only when TM configured and idle; non-TM APFS snapshots (Synology, CCC) are also listed (#1916). Never sized or deleted. |
| Incomplete TM backups | `<volume>/Backups.backupdb/**/*.inProgress\|*.inprogress` (depth <= 3, also APFS bundles); delete via `tmutil delete` | no (prints "try manually with sudo" on failure) | gated | Age >= 48 h; TM must report idle (running or unknown means keep); unreadable mtime means keep; candidate identity re-checked immediately before `tmutil`. |

#### User essentials (`clean_user_essentials`, no sudo)

| Category | Path / command | Default | Safety notes |
|---|---|---|---|
| User app cache | every child of `~/Library/Caches/*` except `Google` (handled in Browsers) and any entry containing the effective `DENO_DIR` | on | Goes through `safe_remove`, so protections apply: whitelist, protected path list, live owner process check, SQLite handle check, compiled-model-cache check (E5RT, `holds_compiled_model_cache`). Guard re-run at the sink. |
| User app logs | children of `~/Library/Logs/*`; `DiagnosticReports` directory itself is kept but its children are cleaned (#1689: deleting the dir broke crash reporting under sandbox) | on | Root bound by inode; redirected root refused. |
| Trash | `~/.Trash` top-level items | on (whitelist "Trash" to keep) | Skipped with a warning if Full Disk Access is missing (listing fails). Items that hold a compiled model cache are skipped. Direct delete, not Finder. |
| Recent items | `~/Library/Application Support/com.apple.sharedfilelist/*.RecentApplications/RecentDocuments/RecentServers/RecentHosts.sfl2` and `.sfl`; `~/Library/Preferences/com.apple.recentitems.plist` | on | Never touches System Settings entries in sharedfilelist. |
| Mail Downloads | `~/Library/Mail Downloads`, `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads` (folder-per-attachment, files at depth 2) | on | See 2.1 (30 d, >= 5120 KB, untouched copy, Mail not running). |
| Incomplete downloads | `~/Downloads/*.download`, `*.crdownload`, `*.part` | on | Open-file (lsof) probe at three points; active downloads skipped; probe unavailable means skip. |
| Finder metadata | `.DS_Store` under `$HOME` (max 500 per scan) and on external volumes | **off** by default whitelist | |
| Support app data | `~/Library/Application Support/CrashReporter/*` > 30 d | on | |
| Messages caches | `~/Library/Messages/StickerCache/*`, `~/Library/Messages/Caches/Previews/{Attachments,StickerCache}/*` | on | Attachments proper never touched. |
| Saved app state | `~/Library/Saved Application State/*` | on | No age filter in `clean`. |
| Misc Apple caches | `~/Library/Caches/com.apple.{photoanalysisd, akd, WebKit.Networking/*, QuickLook.thumbnailcache, iconservices*, helpd/*, AppleMediaServices/*, duetexpertd/*, parsecd/*, python/*, rosetta.update, amp.mediasevicesd}`, `~/Library/Caches/Quick Look/*`, `~/Library/Caches/GeoServices/*`, `~/Library/IdentityCaches/*`, `~/Library/Suggestions/*`, `~/Library/Application Support/AddressBook/Sources/*/Photos.cache` | on | `com.apple.finder` cache is default-whitelisted. |
| Rosetta / media service (Apple Silicon only) | `~/Library/Caches/com.apple.rosetta.update`, `~/Library/Caches/com.apple.amp.mediasevicesd`, `/Library/Apple/usr/share/rosetta/rosetta_update_bundle` | on | The `/Library/Apple/*` path is on Mole's own critical-deny list, so that last call is probably refused by validation *(as read, not executed)*. |
| Apple sandbox containers | `~/Library/Containers/<id>/Data/Library/Caches/*` or `Data/tmp/*` for `com.apple.{mediaanalysisd, AppStore, configurator.xpc.InternetService (tmp), wallpaper.extension.aerials (tmp), geod (tmp), stocks, AvatarUI.AvatarPickerMemojiPicker, AMPArtworkAgent, CoreDevice.CoreDeviceService, NeptuneOneExtension, AppleMediaServicesUI.UtilityExtension (tmp)}` | on | Explicit allow-list; arbitrary Apple containers are not swept. |
| Wallpaper renders | `~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/**/*.bmp` | on | Newest picture kept; folder too large to judge means offers nothing; open-handle probe per file. Incident #999 (Wallpaper settings previews). |
| Handoff clipboard | `~/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/*` older than 60 min | on | |
| Third-party sandbox caches | for every `~/Library/Containers/<bundle-id>` not critical/data-protected: `Data/Library/Caches/*` | on | Symlinks skipped; per-item protection and whitelist re-checks; >100 entries means bulk without sizing. |
| Third-party group containers | for every `~/Library/Group Containers/<id>` not `com.apple.*`/`group.com.apple.*`/`systemgroup.com.apple.*`: `Logs`, `Library/Logs` (and caches for non-protected apps) | on | Safari Web Extension containers skipped (cleaning relaunches Safari). Unreadable containers skipped to avoid TCC prompts. |

#### App caches / Apps & utilities (`clean_app_caches`, `clean_user_gui_applications`)

All user-level, default on, routed through `safe_clean` (so protections above apply). Path pattern `~/Library/Caches/<bundle-id>/*` unless stated.

| Group | Targets |
|---|---|
| Communication | Zoom `us.zoom.xos`; WeChat `com.tencent.xinWeChat`; Telegram `ru.keepcoder.Telegram`; Teams `com.microsoft.teams2`; WhatsApp `net.whatsapp.WhatsApp`; Skype `com.skype.skype`; Tencent Meeting `com.tencent.meeting`; WeCom `com.tencent.WeWorkMac`; QQ `com.tencent.qq`; Feishu `com.feishu.*` (+ Service Worker caches); DingTalk `dd.work.exclusive4aliding`, `com.alibaba.AliLang.osx`, `~/Library/Application Support/iDingTalk/{log,holmeslogs}/*`; Notion Service Worker caches |
| AI apps | `com.openai.chat`, `com.anthropic.claudefordesktop`, `~/Library/Logs/Claude/*`, `com.lmstudio.lmstudio`; stale Claude VM bundles under `~/Library/Application Support/Claude` (7 d, only if app not installed or running) |
| Design / video / 3D | Sketch (`com.bohemiancoding.sketch3`, `Application Support/com.bohemiancoding.sketch3/cache/*`), Figma, ScreenFlow, Final Cut Pro `com.apple.FinalCut`, DaVinci Resolve (`com.blackmagic-design.DaVinciResolve`, `~/Movies/CacheClip/*`), Premiere Pro `com.adobe.PremierePro.*`, Autodesk Fusion (guarded), Blender, Cinema 4D, SketchUp, JianyingPro |
| Media | Apple Music `com.apple.Music`, Podcasts (`com.apple.podcasts` cache, container `tmp/StreamedMedia`, `tmp/*.heic`, `tmp/*.img`, `tmp/*CFNetworkDownload*.tmp`), Apple TV, Plex, NetEase Music, QQ Music (several container subfolders), Kugou, Kuwo, IINA, VLC, MPV, iQIYI, Tencent Video (+ app-support `Upgrade`, `VideoNative`, `documentCache`), Bilibili, Douyu, Huya, SenPlayer, Stremio (+ server cache), Spacedrive thumbnails |
| Downloaders / torrents | aria2 GUI, Transmission, qBittorrent, Downie, Folx, Pacifist, NeatDM stale segments |
| Games | Steam (`Caches/com.valvesoftware.steam`, `Application Support/Steam/{htmlcache,appcache,depotcache,logs}`, `steamapps/shadercache`), Epic, Battle.net, EA, GOG Galaxy, Riot, Minecraft (`logs`, `crash-reports`, `webcache`, `webcache2`), Lunar Client (`~/.lunarclient/{game-cache,launcher-cache,logs,offline/*/logs,offline/files/*/logs}`), PCSX2, RPCS3 |
| Productivity / notes | Notion `notion.id`, Obsidian `md.obsidian`, Logseq, Bear, Evernote, Yinxiang, Alfred, Todoist, Any.do, MiaoYan, Klee, Ora, Filo, Flomo, Quark video cache, NetNewsWire, MindNode, Folo |
| Editors | Sublime Text, Zed (cache and `~/Library/Logs/Zed/*`), obsolete editor extensions |
| Terminals / shell | Warp (cache, `~/Library/Logs/warp.log`, SentryCrash), Ghostty, Kaku; `~/.zcompdump*`, `~/.lesshst`, `~/.viminfo.tmp`, `~/.wget-hsts`, `~/.cacher/logs/*`, `~/.kite/logs/*` |
| Utilities | Input Source Pro, WakaTime, WeType, Stash, The Unarchiver, TeamViewer, AnyDesk, ToDesk, Sunlogin, CleanShot, Camo, Xnip, Spark, Airmail, Youdao, Eudic, Bob |
| Xcode DerivedData | `~/Library/Developer/Xcode/DerivedData/*` per project (see Dev tools) |

#### Browsers (`clean_browsers`)

Process-gated: Chrome/Edge/Brave/Firefox/Arc/Vivaldi/QQBrowser/BrowserOS caches are cleaned only when that browser is not running (a running state defers the family, unknown state prints "skipped").

| Browser | Targets | Notes |
|---|---|---|
| Safari | `~/Library/Caches/com.apple.Safari/*` | Always on. |
| Chrome | `~/Library/Caches/Google/Chrome/*`; under `~/Library/Application Support/Google/Chrome/<profile>/`: `Application Cache`, `Code Cache`, `GPUCache`, `DawnCache`, `GrShaderCache`, `GraphiteDawnCache`; at root: `component_crx_cache`, `ShaderCache`, `GrShaderCache`, `GraphiteDawnCache`, `Crashpad/completed`, `OptGuideOnDeviceModel`, `OptGuideOnDeviceClassifierModel`, `optimization_guide_model_store`; `GoogleUpdater/crx_cache`, `GoogleUpdater/*.old` | The whole `~/Library/Caches/Google` is excluded from the generic sweep and only cleaned after Chrome quits. Chrome on-device AI model folders (`OptGuideOnDevice*`, `optimization_guide_model_store`) are cleaned and also offered as whitelist menu rows. |
| Chromium-family template | `Code Cache`, `GPUCache`, `DawnCache`, `GrShaderCache`, `GraphiteDawnCache`, `DawnGraphiteCache`, `DawnWebGPUCache`, `ShaderCache`, `GPUPersistentCache`, `component_crx_cache`, `extensions_crx_cache`, `Crashpad/completed`, `Application Cache` under the browser's profile roots | Applied to Arc (`~/Library/Application Support/Arc/{*,User Data/*}`), Dia, Brave (`BraveSoftware/Brave-Browser`), Helium (`net.imput.helium`), Yandex, Vivaldi, QQ Browser (`QQBrowser3`), BrowserOS; HTTP caches under `~/Library/Caches/{Chromium, company.thebrowser.Browser, company.thebrowser.dia, Dia, com.microsoft.edgemac, net.imput.helium, Yandex/YandexBrowser, com.operasoftware.Opera, com.vivaldi.Vivaldi, Comet, com.kagi.kagimacOS (Orion), zen, BrowserOS, com.tencent.QQBrowser3}` and `~/.cache/puppeteer/*` |
| Firefox | `~/Library/Caches/Firefox/*`, `~/Library/Application Support/Firefox/Profiles/*/cache2/*` | **Only `cache2`, never the profile.** |
| Service workers | `<profile>/Service Worker/CacheStorage` for Chrome, Arc, Dia, Brave, Vivaldi, and Electron apps | **Skips sites on `PROTECTED_SW_DOMAINS`** (Google Docs/Sheets/Slides/Drive/Mail offline mode, GitHub, GitLab, Notion, Figma, Linear, Excalidraw, CodePen, CodeSandbox, Replit, StackBlitz, CapCut, Photopea, Pixlr). ScriptCache is never touched. |
| Old browser versions | Chrome/Edge/Brave `Contents/Frameworks/<X>.framework/Versions/*` other than `Current` and any newer staged update; Edge updater old versions | May use sudo for `/Applications` owned by root; keeps `Current`. |
| Leaked automation profiles | stale Playwright/Puppeteer/DevTools-MCP temp profiles | Escalates to kill only if the same PID still shows the orphaned-automation signature. |

#### Cloud & Office, Virtualization

| Category | Targets | Notes |
|---|---|---|
| Cloud storage | `~/Library/Caches/com.dropbox.*`, `com.getdropbox.dropbox`, `com.google.GoogleDrive`, `~/Library/Caches/com.microsoft.OneDrive`, Baidu Netdisk `com.baidu.netdisk`, Alibaba `com.alibaba.teambitiondisk`, Box `com.box.desktop` | Process-gated; section budget 300 s. **`~/Library/CloudStorage` and File Provider state are never targeted.** |
| Office | Word / Excel (cache, container Caches, tmp, container Logs), PowerPoint, Outlook, iWork `com.apple.iWork.*`, WPS, Thunderbird, Apple Mail cache | App must not be running. |
| Virtualization | UTM (cache, container cache/tmp), Tart caches, VMware Fusion `com.vmware.fusion`, Parallels `com.parallels.*`, `~/VirtualBox VMs/.cache`, Lima `~/Library/Caches/lima/download/by-url-sha256/*`, `~/.vagrant.d/tmp/*` | VM disks never touched. OrbStack data protected. |

#### Application Support (generic pass)

For each `~/Library/Application Support/<app>` not protected, not critical, and **not running**: only `Code Cache`, `GPUCache`, `DawnCache`, `GrShaderCache`, `GraphiteDawnCache`, `DawnGraphiteCache`, `DawnWebGPUCache`, `Crashpad/completed`, and (only when regenerable-cache markers are present) `Cache`, `CachedData`. Group Containers: explicit `Logs` and `Library/Logs` only. Comment: Application Support can hold licences, databases and session state, so generic cleaning stays on an explicit regenerable subtree list.

#### Developer tools (`clean_developer_tools`)

| Tool | Path / command | sudo | Default | Safety notes |
|---|---|---|---|---|
| Xcode DerivedData | `~/Library/Developer/Xcode/DerivedData/*` (per project) | no | on | Skipped while Xcode/xcodebuild run; protected/whitelisted/compiled-model entries filtered. Listed in the whitelist menu. |
| Xcode internal caches | `~/Library/Caches/com.apple.dt.Xcode/*` (via user-cache sweep), `~/Library/Developer/Xcode/UserData/IB Support/*` | no | on | |
| Xcode DeviceSupport | `~/Library/Developer/Xcode/{iOS,macOS,watchOS,tvOS,visionOS,xrOS} DeviceSupport/*` | no | on | Keeps 2 newest per platform by mtime; also `*/Symbols/System/Library/Caches/*` and `*.log`. Symbols regenerate when a device connects. Metadata unreadable means skip. |
| XCTest devices | `~/Library/Developer/XCTestDevices/*` (entry by entry, root kept) | no | on | Skipped if Xcode/test processes are active. |
| Simulator runtime caches | `~/Library/Developer/CoreSimulator/Profiles/Runtimes/*/Contents/Resources/RuntimeRoot/System/Library/Caches/*` | no | on | Guarded. |
| Unavailable simulators | `xcrun simctl delete unavailable` | n/a | gated | Resolves Xcode via `DEVELOPER_DIR` and refuses until Xcode first-launch finished. |
| Simulator runtimes (orphans) | listed with `xcrun simctl runtime delete <id>` hint | n/a | **review** | Joins by `runtimeIdentifier` from `-j` output (name joins mislabel point releases). |
| Xcode Archives | `~/Library/Developer/Xcode/Archives` | n/a | **review** | Holds dSYMs for shipped builds (issue #756 asked to stop auto-clearing). |
| Simulator Devices | `~/Library/Developer/CoreSimulator/Devices` | n/a | **review** | |
| SwiftPM | `~/.cache/swift-package-manager/*`, `~/Library/Caches/org.swift.swiftpm/*` | no | on | |
| Homebrew | `brew cleanup --prune=30` (preview first with `--dry-run`); `~/Library/Caches/Homebrew/downloads/*`; `brew autoremove` is **review-only** | no | on (whitelist-able) | At most once per 7 days; restores `bin` links that cleanup removed; autoremove excluded because venv/pyenv/cargo links can be invisible to brew (#1093). |
| npm | `npm cache clean --force`; plus `~/.npm/{_cacache,_logs,_prebuilds}/*` (`_npx` is deliberately kept because running commands read it); custom cache path honoured; `~/.tnpm/_cacache/*`, `~/.tnpm/_logs/*` | n/a | on | |
| pnpm | pnpm stores via `clean_pnpm_stores`; `~/Library/Caches/pnpm/metadata*/*` | n/a | on | `pnpm/dlx` protected; store root also listed as **review** with per-major-layout stores. |
| Yarn | `~/Library/Caches/Yarn/*` (v1) | no | on | `~/.yarn/berry/cache` protected. |
| Bun | `bun pm cache rm` | n/a | on | |
| Corepack | `$COREPACK_HOME/*` | no | on | Usable binary only. |
| pip / Python | `pip3 cache purge`; `~/.pyenv/cache/*`; Poetry `~/.cache/poetry/*`, `~/Library/Caches/pypoetry/{artifacts,cache}/*` (**not** `virtualenvs`); `uv cache` (`~/.cache/uv`); `~/.cache/ruff/*`, `~/.cache/mypy/*`, `~/.pytest_cache/*`; PyInstaller bincache; Clang module cache under DARWIN_USER_DIR; conda `conda clean --yes --index-cache --tarballs --logfiles` | n/a | on | conda `pkgs` stores themselves are review-only. |
| Rust | `$CARGO_HOME/registry/cache/*`, `$RUSTUP_HOME/downloads/*` | no | on | **Keeps** `registry/src`, `registry/index`, `git`, `bin`, toolchains (src is needed for offline builds and rust-analyzer; cargo 1.88+ garbage-collects src itself). |
| Go | `go clean -modcache` and `go clean -cache` (env pinned to the resolved physical `GOMODCACHE`/`GOCACHE`) | n/a | on | Roots re-bound at the command boundary; each root separately whitelist-able. |
| Gradle | `~/.gradle/{notifications,daemon,workers}/*`, `~/.gradle/caches/build-cache-*/*` | no | **off** (default whitelist covers `~/.gradle/caches/*` and `daemon/*`) | `~/.gradle/caches` (modules-2 dependency store) is shown as **review**. Gradle daemon running means skip. |
| Maven / Ivy / sbt / NuGet | `~/.m2/repository`, `~/.ivy2/cache`, `~/.nuget/packages` | n/a | **review** | Maven delete path was *removed*: it relied on the default whitelist and became unsafe once users saved custom entries. |
| CocoaPods / Flutter / Dart | `~/Library/Caches/CocoaPods/*`, `~/.cache/flutter/*`, `~/.pub-cache/*` | no | **disabled** | Delete calls are commented out in `dev.sh`; CocoaPods still appears in the whitelist menu. |
| Ruby / Perl / Opam / Hex | `~/.rbenv/cache/*`, `~/.gem/specs/*`, `~/.gem/ruby/*/cache/*.gem`, `~/.bundle/cache/*`, `~/.cpan/build/*`, `~/.opam/download-cache/*`, `~/.hex/cache/*` | no | on | Haskell Stack/cabal deliberately not cleaned. |
| PHP | `~/.composer/cache/*`, `~/Library/Caches/composer/*` | no | on | |
| Deno | children of effective `DENO_DIR` cache, **except** the root | no | on | `deno clean` equivalent would remove origin storage; Mole refuses if the root changes mid-run. Deno module cache is review-only. |
| mise | `mise cache clear` or `$MISE_CACHE_DIR/*` | n/a | on | `~/.local/share/mise/installs` is review-only. |
| Docker | `docker image prune -f` (dangling only); `docker builder prune -f --filter until=168h` pinned to the local context's builder; `~/.docker/buildx/cache/*`; `~/.local/share/containers/storage/tmp/*` | n/a | on | **Never prunes volumes or tagged images.** Docker Desktop data (`~/Library/Containers/com.docker.docker/Data`) is **review**, and its whitelist row turns the prune off. Remote contexts are not touched. |
| Nix | `nix-store --gc` | n/a | on | |
| Cloud CLIs | `~/.kube/cache/*`, `~/.aws/cli/cache/*`, `~/.config/gcloud/logs/*`, `~/.azure/logs/*`, `~/.cache/terraform/*`, `~/.grafana/cache/*`, GitHub CLI cache (`$XDG_CACHE_HOME` aware) | no | on | |
| JS tooling | `~/.cache/{typescript,electron,node-gyp,vite,webpack,eslint,prettier,prisma,opencode,pre-commit,curl,wget}/*`, `~/.node-gyp/*`, `~/.turbo/cache/*`, `~/.vite/cache/*`, `~/.parcel-cache/*`, `~/Library/Caches/{curl,wget}/*`, `~/.oh-my-zsh/cache/*` | no | on | `Next.js ~/.next` and `Turbo` appear in the whitelist menu. |
| Build systems / CI | `~/.cache/{bazel,zig,gitlab-runner}/*`, `~/.jenkins/workspace/*/target/*`, `~/.github/cache/*`, `~/.circleci/cache/*`, `~/.sonar/*` | no | on | Bazel cache is in the whitelist menu. |
| Expo / RN | `~/.expo/{expo-go,android-apk-cache,ios-simulator-app-cache,native-modules-cache,schema-cache,template-cache,versions-cache}/*` | no | on | **`state.json` kept (auth tokens).** |
| Android | `~/.android/build-cache/*`, `~/.android/cache/*`, `~/Library/Caches/Google/AndroidStudio*/*` | no | on | AVDs, SDK system images, SDK itself: review-only. |
| JetBrains | Toolbox old IDE builds (keep 1), `~/Library/Logs/JetBrains/*` | no | on for logs and old builds; **off** for JetBrains caches/AppSupport (default whitelist) | Per-version data dirs (`GoLand2025.1` and so on) are **review-only** (#1179: they enable downgrades). |
| DB / API clients | Sequel Ace/Pro, Redis Desktop Manager, Navicat, DBeaver, RedisInsight, Postman, Insomnia, TablePlus, Paw, Charles, Proxyman, Unity `com.unity3d.*`, MongoDB Compass, Figma, GitHub Desktop, SentryCrash, KSCrash, Crashlytics (all `~/Library/Caches/<id>/*`) | no | on | |
| Crash SDK reports | `~/Library/Caches/{SentryCrash,KSCrash,com.crashlytics.data}/*` | no | on | |
| AI coding agents (versions) | old versions under `~/.local/share/claude/versions`, `~/.local/share/cursor-agent/versions`, `~/.copilot/pkg/universal`, Claude Desktop bundled `claude-code[-vm]`, Codex CLI runtimes, Codex daemon old releases, Codex stale update staging | no | on | Keeps active version and previous one (`keep_previous=1`); active symlink unknown means keep all. |
| AI agent logs/caches | `~/.local/share/cursor-agent/*.log` > 7 d; Chromium `Default/{Cache,Code Cache,GPUCache,DawnGraphiteCache,DawnWebGPUCache}/*` for Antigravity/Gemini/Chrome DevTools MCP profiles | no | on | **Sessions, memory, auth, history are protected** (see 2.5 incident #823 and #913). |
| Project caches | `__pycache__` (bytecode only), `.next/cache` children, `.dart_tool` under discovered project roots | no | on | Name-only discovery; **anything git tracks is kept**, nested repos skipped, project root needs a manifest/`.git`. Heavy dirs pruned (`node_modules`, `.git`, `Library`, `.venv`, `Pods`, `DerivedData`...). |
| Mole's own analyzer cache | `~/.cache/mole/*.cache` (legacy flat files, one user had 1.88 M files / 7.8 GB) | no | on | Background, resumable. |
| Wondershare payload | `~/Library/Application Support/com.wondershare.Installer/*` | no | on | |

#### App leftovers (`apps.sh`)

| Category | Path | Default | Safety notes |
|---|---|---|---|
| Orphaned Caches / Logs | `~/Library/Caches/{com.*,org.*,net.*,io.*}`, `~/Library/Logs/{com.*,org.*,net.*,io.*}` whose bundle id has no installed app | gated | Needs **all** of: not in protection list; not on `ORPHAN_NEVER_DELETE_PATTERNS` (`*1password*`, `*keychain*`, `*bitwarden*`, `*lastpass*`, `*keepass*`, `*dashlane*`, `*enpass*`, `*ssh*`, `*gpg*`, `*gnupg*`, `com.apple.keychain*`); not in installed-bundle list (scans `/Applications`, `~/Applications`, Homebrew Cask paths, Setapp, iOS-on-Mac wrappers, PlayCover aliases; incomplete scan blocks all orphan decisions); mtime older than 30 d; mdfind fallback (timeout means treat as installed); re-checked after sizing. Max 100 iterations per pattern. |
| Orphaned saved state | `~/Library/Saved Application State/*.savedState` | gated | Same checks. |
| Claude VM bundles | `~/Library/Application Support/Claude/*vm*` | gated | 7 d, app not installed or running. |
| Orphaned system services | `/Library/LaunchDaemons`, `/Library/LaunchAgents`, `/Library/PrivilegedHelperTools` entries whose binary is gone | gated, **sudo** | Force-protect list for known live helpers; vendors that need their own uninstaller (MDM, EDR, VPN, Intego, Symantec/Broadcom) are never orphans. |
| Container stubs | empty `~/Library/Containers/<bundle-id>` stubs (removed with `rmdir`, not `rm -r`) | gated | Only when the container holds no user content and neither a common install location nor `mdfind` finds the app; `rmdir` means a container that gains a file between check and removal survives. Bundle-id/app-path pairs exist to exempt known apps (for example CleanMyMac helpers). The orphan sweep for *data* deliberately excludes `LaunchAgents`, `LaunchDaemons`, `Containers/`, `Application Scripts/`, `Group Containers/` (source comments). |

#### Device backups & firmware, Time Machine, Large files

| Category | Path | Default | Notes |
|---|---|---|---|
| Cached device firmware | `~/Library/iTunes/{iPhone,iPad,iPod,Apple TV} Software Updates/*.ipsw`; `~/Library/Group Containers/*.group.com.apple.configurator/**/*.ipsw` | on | Open or unverified files kept; device backups and partial downloads never scanned. |
| iOS device backups | `~/Library/Application Support/MobileSync/Backup` | **review** | Row shows size and newest-child date ("100 GB of last month's phone backup is the only copy of that phone"). Never deleted by `clean`. |
| Large-file review rows (>= 1 GB bar) | Mail data `~/Library/Mail`, `~/Library/Mail Downloads`, `~/Library/Updates`, macOS installers, Docker Desktop data, OrbStack, Lima, LM Studio models, Hugging Face cache, Android emulators/system images, FVM Flutter SDKs, mise installs, Conductor workspaces, AI worktrees (`<project>/.claude/worktrees`, `~/.codex/worktrees`, `~/.t3/worktrees`), compiled model caches (E5RT), conda/Anaconda pkgs | **review** | Report only. |
| Project artifacts | `mo purge` list: `node_modules`, `target`, `build`, `dist`, `venv`, `.venv`, `.pytest_cache`, `.mypy_cache`, `.tox`, `.nox`, `.ruff_cache`, `.gradle`, `.terragrunt-cache`, `__pycache__`, `.next`, `.nuxt`, `.output`, `vendor`, `bin`, `obj`, `.turbo`, `.parcel-cache`, `.dart_tool`, `.zig-cache`, `zig-out`, `.angular`, `.svelte-kit`, `.astro`, `coverage`, `DerivedData`, `Pods`, `.cxx`, `.expo`, `.build` | `mo clean`: **hint only**; `mo purge`: user-selected, permanent | Search roots `~/www ~/dev ~/Projects ~/GitHub ~/Code ~/Workspace ~/Repos ~/Development ~/Library/CloudStorage ~/.codex/worktrees ~/.claude/worktrees ~/.t3/worktrees`. Project indicators: `package.json`, `Cargo.toml`, `go.mod`, `pyproject.toml`, `pom.xml`, `build.gradle`, `Gemfile`, `composer.json`, `pubspec.yaml`, `Package.swift`, `Makefile`, `.git`. `bin`/`vendor` guarded. Honours `CACHEDIR.TAG` signature. |
| Installer files (`mo installer`) | `.dmg .pkg .mpkg .iso .xip .zip` in `~/Downloads`, `~/Desktop`, `~/Documents`, `~/Library/Downloads`, `/Users/Shared/Downloads`, `~/Library/Caches/Homebrew`, iCloud `~/Library/Mobile Documents/com~apple~CloudDocs/Downloads`, Mail Downloads, Telegram Desktop folders | user-selected | Separate command, permanent delete. |

### 2.3 `mo optimize` (maintenance, not space cleaning, but it deletes some data)

Catalog tasks (all flagged safe for auto-run): refresh QuickLook/icon services cache, saved-state cleanup (>30 d), fix corrupted preferences, flush DNS, VACUUM SQLite (Mail, Safari, Messages; skipped if apps run; max 100 MB), prevent network `.DS_Store`, remove legacy App Nap overrides, flush routing/ARP, repair user dir permissions, Spotlight rebuild/orphan rules, periodic maintenance scripts, repair shared file lists, disk verify, login-items audit, clear Gatekeeper quarantine history, report LaunchAgents with missing binaries, clean old notifications, clean CoreDuet usage data.

### 2.4 `mo slim` and `mo uninstall` (relevant to language packs / leftovers)

`slim` removes Intel slices from universal apps (Developer-ID-signed apps only; works on a copy, requires the copy to keep its Apple Silicon signature, then replaces). `uninstall` routes to Trash by default (`--permanent` skips), uses `.lproj` folders only to read localized app names, and runs a leftover finder over Library paths.

### 2.5 Incidents and bugs (Mole issues, all closed)

| Issue | Date | What happened | Fix / rule it produced |
|---|---|---|---|
| [#823](https://github.com/tw93/Mole/issues/823) | 2026-05 | `clean` permanently deleted Claude Code `~/.claude/projects/*/memory/` (months of irreplaceable notes; no Trash, no backup) | Maintainer reply: "Mole no longer cleans Claude Code state under `~/.claude`" (nightly). In current `clean`, `~/.codex/{sessions,auth.json,history.jsonl,state_*.sqlite}` are on the protected list; `~/.claude` protection is by not targeting it. |
| [#913](https://github.com/tw93/Mole/issues/913) | 2026-05 | Codex project conversation history at risk during cleanup | Codex state paths are in `should_protect_path` |
| [#1689](https://github.com/tw93/Mole/issues/1689) | 2026-10 | `~/Library/Logs/DiagnosticReports` directory deleted; macOS could not recreate it under sandbox, crash reports lost | Delete children, keep the directory |
| [#1670](https://github.com/tw93/Mole/issues/1670) (Mole Mac app) | 2026-10 | Trashed `~/Library/Preferences/*.plist`, `HTTPStorages` and `.binarycookies` of apps judged "uninstalled"; apps asked for licence keys again | Current orphan sweep (as read) covers only `~/Library/{Caches,Logs,Saved Application State}`; Preferences and HTTPStorages are not orphan targets |
| [#1590](https://github.com/tw93/Mole/issues/1590) (Mole Mac app) | 2026-09 | Active Clash profile data `~/Library/Application Support/com.follow.clash` trashed as orphan | Current state (as read): Clash-family names in the data-protected list; no Application Support orphan sweep |
| [#1854](https://github.com/tw93/Mole/issues/1854) | 2026-10 | `~/Library/Caches/kitty` deleted while Kitty ran, breaking graphics protocol | Added to hard safety whitelist |
| [#1188](https://github.com/tw93/Mole/issues/1188) | 2026-07 | `clean` broke Intego One (self-protecting AV with root-only `/Library/Intego`) | Intego/Symantec/Broadcom treated as never orphaned |
| [#1427](https://github.com/tw93/Mole/issues/1427) | 2026-08 | `mo purge` ignored the whitelist (never loaded it) | README now states `clean`, `purge` and `optimize` stop if the whitelist cannot be read |
| [#204](https://github.com/tw93/Mole/issues/204) | 2025-12 | `optimize` removed valid LaunchAgents ("orphaned helper" check used `Program` but many plists use `ProgramArguments`); `--dry-run` did not stop deletions | `optimize` task now only *reports* LaunchAgents whose binary is missing (catalog text) |
| [#999](https://github.com/tw93/Mole/issues/999) | 2026-05 | `clean`/`optimize` removed Wallpaper settings icon previews | Current code keeps the newest wallpaper render and protects `com.apple.idleassetsd`/`com.apple.wallpaper` (a comment cites #1118); the link to #999 itself is not confirmed |
| [#484](https://github.com/tw93/Mole/issues/484) | 2026-02 | Firefox font rendering broke after `optimize` | `com.apple.FontRegistry*` is now hard-whitelisted (comment says removal breaks font rendering; link to #484 inferred) |
| [#1446](https://github.com/tw93/Mole/issues/1446), [#993](https://github.com/tw93/Mole/issues/993), [#1475](https://github.com/tw93/Mole/issues/1475) | 2026-07/08 | `uninstall` trashed an entire `~/.local`, same-named CLI data (XDG dot-dir heuristic), and live data after a Sparkle in-place update | Uninstall-side lessons: never infer ownership from a name match |
| Code comment (no issue) | 2026 | Removing staged update payloads on a macOS 27 beta left a Mac unbootable | `/Library/Updates` and `/macOS Install Data` never cleaned; installer deletion fail-closed |
| Code comment (#1584) | 2026 | A Spotlight (`mdfind`) timeout cached "not installed", so a live app's data was deleted | Timeout means keep, never cache a negative |

---


## 3. mac-cleanup-py (P)

Source: `mac_cleanup/default_modules.py` (all targets), `core_modules.py`, `utils.py`, `main.py`, `config.py`.

### 3.1 Safety mechanisms

| Mechanism | Detail |
|---|---|
| Opt-in modules | First run opens a checkbox screen (`inquirer`) with **nothing checked**; only checked modules run (`-c` reconfigures). Config at `~/.mac_cleanup_py` or `$XDG_CONFIG_HOME/mac_cleanup_py/config.toml`. Custom modules via `-p`. |
| Prompts | Modules can carry `.with_prompt(...)`. `-f/--force` auto-accepts every prompt. Prompted: all of `~/Library/Caches/*`, simulator erase, Gradle caches, Docker prune, Poetry, Java heap dumps, Telegram, NuGet. |
| Dry-run | `-n`: sums sizes with a glob-aware `du`; `-v` prints each path; then asks "Continue?" and runs. Many `Command` modules (gem, docker, brew cleanup) have no dry-run size. Issue #279 (open): `-n` estimated about 80 GB while the real run freed 0 B. |
| Delete mechanism | `Path` runs `rm -rf '<path>'` through a shell (permanent; no Trash). Commands run via `Popen(shell=True)`; stderr discarded by default. |
| Privileges | Issue #150 (closed): sudo was removed as the default. Current `Path` execution is plain `rm -rf` as the invoking user, so root-owned targets silently fail unless the whole tool is run under `sudo` (the issue #279 reporter does that). Only `dns_cache` and `inactive_memory` hard-code `sudo`. |
| Path guard `check_deletable` | Refuses prefixes `/System /usr /sbin /Applications /Library /usr/local` and `~/Documents ~/Downloads ~/Desktop ~/Movies ~/Pictures`, and anything with the `com.apple.rootless` xattr. **Any path containing `*` returns True before these checks** *(as read)*, so globs such as `/Library/Logs/DiagnosticReports/*` pass while the non-glob `/Library/Logs/adobegc.log` is refused. |
| Running apps | Kills specific apps rather than detecting them: `killall 'Google Drive File Stream'`, `killall -KILL Telegram` then relaunches, Docker started with `open -jga Docker` and `killall Docker` afterwards, simulators quit via `osascript`. No lsof or process gate for caches in general. |
| SIP | Only the prefix list plus the rootless xattr test. |
| iCloud / Photos / Mail | No explicit handling. `~/Library/Containers/com.apple.mail/Data/Library/Logs/Mail/*` (logs) only. `~/Library/Caches/*` includes `CloudKit` and Mail caches with no exclusions. |

### 3.2 Targets

| Module | Path / command | sudo | Default | Safety notes |
|---|---|---|---|---|
| trash | `/Volumes/*/.Trashes/*`, `~/.Trash/*` | no | opt-in | All mounted volumes. |
| system_caches | `~/Library/Caches/*` | no | opt-in, **prompted** | Prompt names Poetry, JetBrains, Cocoa, yarn, Composer. No exclusions. |
| system_caches | `/private/var/folders/bh/*/*/*/*` | no (fails on root-owned) | opt-in | Hard-coded `bh` shard (carried over from the shell script); matches only if that shard exists. Deletes anything four levels down (C, T, 0, X). |
| system_log | `/private/var/log/asl/*.asl`, `/Library/Logs/DiagnosticReports/*`, `/Library/Logs/CreativeCloud/*`, `/Library/Logs/Adobe/*`, `/Library/Logs/adobegc.log`, `~/Library/Containers/com.apple.mail/Data/Library/Logs/Mail/*`, `~/Library/Logs/CoreSimulator/*` | no | opt-in | |
| jetbrains | `~/Library/Logs/JetBrains/*/` | no | opt-in | Only if dir exists. |
| adobe | `~/Library/Application Support/Adobe/Common/Media Cache Files/*` | no | opt-in | |
| chrome | `~/Library/Application Support/Google/Chrome/Default/Application Cache/*` | no | opt-in | Only the legacy app cache of the Default profile. (Shell script issue #43 once wiped a Chrome profile.) |
| ios_apps | `~/Music/iTunes/iTunes Media/Mobile Applications/*` | no | opt-in | |
| ios_backups | `~/Library/Application Support/MobileSync/Backup/*` | no | opt-in, **no prompt** | Permanent delete of device backups. |
| xcode | `~/Library/Developer/Xcode/{DerivedData,Archives,iOS Device Logs}/*` | no | opt-in, no prompt | Archives deleted with no prompt. |
| xcode_simulators | `xcrun simctl shutdown all`; `xcrun simctl erase all`; quits CoreSimulatorService/Simulator via `osascript` | no | opt-in, **prompted** | Erases every simulator's content and settings. Size-only (dry-run) globs for `Devices/*/data/...`. |
| dropbox | `~/Dropbox/.dropbox.cache/*` | no | opt-in | |
| google_drive | `~/Library/Application Support/Google/DriveFS/[0-9a-zA-Z]*/content_cache` | no | opt-in | Kills Drive first. |
| composer | `composer clearcache --no-interaction` | n/a | opt-in | |
| steam | `~/Library/Application Support/Steam/{appcache,depotcache,logs,steamapps/shadercache,steamapps/temp,steamapps/download}` | no | opt-in | `steamapps/download` can hold in-progress game downloads. |
| minecraft | `~/Library/Application Support/minecraft/{logs,crash-reports,webcache,webcache2,*.log,launcher_cef_log.txt,command_history.txt,.mixin.out}` | no | opt-in | |
| lunarclient | `~/.lunarclient/{game-cache,launcher-cache,logs,offline/*/logs,offline/files/*/logs}` | no | opt-in | |
| wget_logs | `~/wget-log`, `~/.wget-hsts` | no | opt-in | |
| cacher / kite | `~/.cacher/logs`, `~/.kite/logs` | no | opt-in | |
| android | `~/.android/cache` | no | opt-in | |
| gradle | `~/.gradle/caches` | no | opt-in, **prompted** ("chunky and kinda long to reinstall") | Includes `modules-2`. |
| brew | `brew cleanup -s`; `rm -rf $(brew --cache)`; `brew tap --repair`; with `-u`: `brew update && brew upgrade` | n/a | opt-in | `brew --cache` output is trusted as-is (PureMac issue #48 shows the `HOMEBREW_CACHE` hijack risk). |
| gem | `gem cleanup` | n/a | opt-in | |
| docker | `docker system prune -af` (starts Docker if stopped, stops it after) | n/a | opt-in, **prompted** | Prompt text says stopped containers, dangling images, unused networks, volumes and build cache will go. |
| pyenv | `$PYENV_VIRTUALENV_CACHE_PATH` | no | opt-in | Trusts an environment variable as a delete target. |
| npm | `npm cache clean --force` | n/a | opt-in | |
| pnpm | `pnpm store prune` | n/a | opt-in | |
| yarn | `yarn cache clean --force` | n/a | opt-in | |
| bun | `bun pm cache rm` | n/a | opt-in | |
| pod | `pod cache clean --all` | n/a | opt-in | |
| go | `go clean -modcache` | n/a | opt-in | |
| microsoft_teams | `~/Library/Application Support/Microsoft/Teams/{IndexedDB,Cache,Application Cache,Code Cache,blob_storage,databases,gpucache,Local Storage,tmp,*logs*.txt,watchdog,*watchdog*.json}` | no | opt-in | Resets classic Teams (signs out). |
| poetry | `~/Library/Caches/pypoetry` | no | opt-in, **prompted** ("All non-local Poetry venvs will be deleted") | Includes `virtualenvs`. Mole protects that subfolder. |
| java_cache | `~/*.hprof` | no | opt-in, prompted | Heap dumps in the home root only. |
| dns_cache | `sudo dscacheutil -flushcache`; `sudo killall -HUP mDNSResponder` | yes | opt-in | Issue #192 (open): hangs. |
| inactive_memory | `sudo purge` | yes | opt-in | |
| telegram | `~/Library/Group Containers/*.ru.keepcoder.Telegram/stable/account-*/postbox/db` | no | opt-in, prompted | Kills Telegram (`-KILL`) and reopens it. The path is the local message database, described as a cache. High risk. |
| conan | `conan remove "*" -c`; `~/.conan2/p/` | n/a | opt-in | |
| nuget_cache | `~/.nuget/packages/` | no | opt-in, prompted | |
| obsidian_caches | `~/Library/Application Support/obsidian/{Cache,Code Cache,DawnGraphiteCache,DawnWebGPUCache,*.log}` | no | opt-in | Vault untouched. |
| ea_caches | `~/Library/Application Support/Electronic Arts/EA app/{IGOCache,Logs,OfflineCache,CEF/BrowserCache/EADesktop/{Cache,Code Cache,DawnCache,GPUCache}}` | no | opt-in | |
| chromium_caches | `~/Library/Application Support/Chromium/{GraphiteDawnCache,GrShaderCache,ShaderCache,Default/DawnCache,Default/GPUCache}` | no | opt-in | |
| arc | `~/Library/Caches/Arc`, `~/Library/Caches/CloudKit/company.thebrowser.Browser`, `~/Library/Caches/company.thebrowser.Browser`, and under `Application Support/Arc/User Data/Default/`: `History`, `History-journal`, `Cookies`, `Cookies-journal`, `Web Data`, `Web Data-journal` | no | opt-in, **no prompt** | Message says "cache, cookies, history, site data": a privacy wipe that logs you out of sites and drops saved autofill, not just a cache clean. |

### 3.3 Incidents (issue search)

- [#38](https://github.com/mac-cleanup/mac-cleanup-py/issues/38): the old bash script, run with sudo, deleted all Docker images and exited containers. Led to `with_prompt`.
- [#150](https://github.com/mac-cleanup/mac-cleanup-py/issues/150): unnecessary sudo for user-only deletes; sudo made opt-in.
- [#279](https://github.com/mac-cleanup/mac-cleanup-py/issues/279) (open): dry-run estimate 80 GB vs 0 B freed. Shows the cost of a size estimate that does not run the same predicates as the delete.
- No reported data-loss issue found in the py repo itself via search ("deleted", "data loss", "broke", "lost", "removed").

---

## 4. mac-cleanup-sh (S) (unmaintained since 2023-05-21)

Single file `mac-cleanup` (about 400 lines). It is the ancestor of P: same targets minus the P-only modules (arc, chromium, ea, obsidian, nuget, conan, telegram, bun, pnpm/yarn dry-run extras, Poetry prompts).

### 4.1 Safety mechanisms

- `sudo -v` at start with a background keep-alive; everything runs with an unlocked sudo session but `rm -rfv` is invoked without `sudo`, so root-owned targets fail silently.
- No prompts and no module selection. `--dry-run` (`-d`) sums sizes with `sudo du`, then asks to continue and re-execs the real run.
- No path validation, no protected-path list, no process checks. `-v` is `set -x`.
- Delete is permanent `rm -rfv ... &>/dev/null`.

### 4.2 Targets (all default **on**, no confirmation)

| Category | Path / command | Notes |
|---|---|---|
| Trash | `/Volumes/*/.Trashes/*`, `~/.Trash/*` | |
| System caches | `/Library/Caches/*`, `/System/Library/Caches/*`, `~/Library/Caches/*`, `/private/var/folders/bh/*/*/*/*` | `/System/Library/Caches` is SIP-protected so the delete fails. All user caches with no exclusions. |
| Logs | `/private/var/log/asl/*.asl`, `/Library/Logs/DiagnosticReports/*`, `/Library/Logs/CreativeCloud/*`, `/Library/Logs/Adobe/*`, `/Library/Logs/adobegc.log`, `~/Library/Containers/com.apple.mail/Data/Library/Logs/Mail/*`, `~/Library/Logs/CoreSimulator/*`, `~/Library/Logs/JetBrains/*/` | |
| Adobe / Chrome | `~/Library/Application Support/Adobe/Common/Media Cache Files/*`, `.../Google/Chrome/Default/Application Cache/*` | |
| iOS | `~/Music/iTunes/iTunes Media/Mobile Applications/*`, `~/Library/Application Support/MobileSync/Backup/*` | Device backups deleted without a prompt. |
| Xcode | `~/Library/Developer/Xcode/DerivedData/*`, `.../Archives/*`, `.../iOS Device Logs/*`, `xcrun simctl erase all` | **Bug *(as read)*:** `collect_paths ~/Library/Developer/Xcode/iOS Device Logs/*` is unquoted, so the spaces split it into three arguments (`.../iOS`, `Device`, `Logs/*`); `Device` and `Logs/*` become paths relative to the current directory. |
| Cloud | `~/Dropbox/.dropbox.cache/*`, `.../Google/DriveFS/*/content_cache` (kills Drive) | |
| Games | Steam, Minecraft, Lunar Client (same paths as P) | |
| Dev | `~/.android/cache`, `~/.gradle/caches`, `~/.kite/logs`, `~/.cacher/logs`, `$(brew --cache)` + `brew cleanup -s` + `brew tap --repair`, `gem cleanup`, `docker system prune -af` (**silent, no prompt**), `$PYENV_VIRTUALENV_CACHE_PATH`, `npm cache clean --force`, `yarn cache clean --force`, `pnpm store prune`, `pod cache clean --all`, `go clean -modcache`, `~/Library/Caches/pypoetry` | The README claims pip cache cleanup but no pip command exists in the script. |
| Misc | Teams caches (as P), `~/*.hprof`, `~/wget-log`/`~/.wget-hsts` (guarded by `-d` on a *file*, so effectively never runs), `sudo dscacheutil -flushcache`, `sudo killall -HUP mDNSResponder`, `sudo purge` | A dry-run branch hard-codes `/Users/wah/...` for simulator paths. |

### 4.3 Incidents

- [#43](https://github.com/mac-cleanup/mac-cleanup-sh/issues/43) (2020): the whole Chrome profile was deleted; fixed by narrowing to the Application Cache path. Maintainer: "plans to rewrite the code, with tests".
- [#112](https://github.com/mac-cleanup/mac-cleanup-sh/issues/112) (2022): user reports it "deleted a ton of useful stuff" including Xcode-related links. Vague, but consistent with the unquoted-path bug above.

---

## 5. mac-cleaner-cli (C)

Source: `src/scanners/*.ts`, `src/utils/{paths,fs,backup,config}.ts`, `src/maintenance/*.ts`, `src/types.ts`, `CHANGELOG.md`.

### 5.1 Safety mechanisms

| Mechanism | Detail |
|---|---|
| Safety levels | Each category is `safe`, `moderate` or `risky` with a note shown before confirming. `clean --all` runs only non-risky categories; `--risky`/`--unsafe` adds risky ones. Confirmation prompt defaults to **No**. |
| Dry-run | `-d/--dry-run`. The protected-path check runs **before** the dry-run early return so a dry run never promises space the real run would refuse (fixed bug). |
| Delete mechanism | `rm(recursive, force)` (permanent) unless `backupEnabled: true` in `~/.maccleanerrc`, in which case items move to `~/.mac-cleaner-cli/backup/<ISO-timestamp>/` (restore with `backup --restore`, auto-purge after 7 days). Default is **off**. |
| Path guard | Protected prefixes: `/System /usr /bin /sbin /etc /var/log /var/db /var/root /private/var/db /private/var/root /private/var/log /Library/Apple /Applications/Utilities`; exceptions allowed for `/tmp /private/tmp /var/tmp /private/var/tmp /var/folders /private/var/folders`. Refuses the home directory itself. Rejects `..` traversal and paths escaping `$HOME` (`expandPath`). `lstat` re-check immediately before delete; symlinks are `unlink`ed, never followed. |
| Running apps | No process or open-file checks in the scanners (only `pgrep` in its own app installer). |
| SIP | Prefix list only. |
| Full Disk Access | `utils/fda.ts` detects and warns. |
| Config | `~/.maccleanerrc` (`excludeCategories`, `backupEnabled`). `MAC_CLEANER_DEBUG=1` logs every skipped path. Scanner failures exit with code 1. |
| Sudo | Not used for cleaning. Maintenance subcommands use `sudo -n` only when allowed without a password. |

### 5.2 Targets

| Category id | Safety | Path / command | sudo | Default (with `clean --all`) | Notes |
|---|---|---|---|---|---|
| `system-cache` | moderate | children of `~/Library/Caches` | no | on | `/Library/Caches` is defined but not scanned. No exclusions of live caches. |
| `system-logs` | moderate | children of `~/Library/Logs`, plus `/var/log` | no | on | `/var/log` is on the protected list, so those items are reported as PROTECTED failures. |
| `temp-files` | safe | children of `/tmp` and `/private/var/folders/*/*/T/*` | no | on | No age filter seen. |
| `trash` | safe | children of `~/.Trash` | no | on | |
| `browser-cache` | safe | `~/Library/Caches/Google/Chrome`, `~/Library/Caches/com.apple.Safari`, `~/Library/Caches/Firefox/Profiles`, `~/Library/Caches/company.thebrowser.Browser` | no | on | Whole directories; no check that the browser is closed. |
| `dev-cache` | moderate | `~/.npm/_cacache`, `~/Library/Caches/Yarn`, `~/Library/pnpm/store`, `~/.cache/pip`, `~/Library/Caches/CocoaPods`, `~/.gradle/caches`, `~/.cargo/registry` (whole, including `src`), children of `~/Library/Developer/Xcode/DerivedData`, `~/Library/Developer/Xcode/Archives` | no | on | Archives are deleted even though they hold shipped-build dSYMs. Gradle `modules-2` and the Cargo source store are included. |
| `homebrew` | moderate | `brew cleanup --prune=all`; `brew --cache` validated against known cache prefixes | n/a | on | Removes all old formula versions, not just downloads. Brew path found only in known safe locations. |
| `docker` | moderate | `docker image prune -a -f`, `docker container prune -f`, `docker builder prune -a -f` | n/a | on | **Volumes deliberately excluded** (comment: volumes are user data). |
| `node-modules` | moderate | `node_modules` under `~/Projects ~/Developer ~/Code ~/dev ~/workspace ~/repos` (depth 4) where the parent project is older than 30 d (or no `package.json`) | no | on | |
| `launch-agents` | moderate | `~/Library/LaunchAgents/*.plist` whose `Program` path no longer exists | no | on | Skips relative paths and system binaries. |
| `downloads` | **risky** | files in `~/Downloads` older than 30 d | no | off | Not recursive. |
| `ios-backups` | **risky** | `~/Library/Application Support/MobileSync/Backup/*` | no | off | "DANGER" note. |
| `mail-attachments` | **risky** | `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/*` | no | off | |
| `language-files` | **risky** | `/Applications/*.app/Contents/Resources/*.lproj` except `en en_US en_GB pt pt_BR pt_PT Base` | no | off | Note says this **breaks the app code signature** and updates may fail. |
| `large-files` | **risky** | files >= 500 MB under `~/Downloads` and `~/Documents` (depth 3) | no | off | Review each. |
| `duplicates` | **risky** | identical-content files | no | off | Keeps newest by default. |
| `git-worktrees` | **risky** | stale or orphaned worktrees under `~/.cursor/worktrees`, `~/.codex/worktrees`, `~/.claude/worktrees` and project worktrees (7 d default) | no | off | "May contain uncommitted work". |
| maintenance `--dns` | | `dscacheutil -flushcache`, `killall -HUP mDNSResponder` | sudo -n | opt-in | |
| maintenance `--purgeable` | | `/usr/sbin/purge` | sudo -n | opt-in | |
| maintenance `--timemachine` | | `tmutil listlocalsnapshotdates`, `tmutil deletelocalsnapshots <date>` (dates validated before use) | sudo -n | opt-in, asks | Added with `--dry-run` and `--yes` in a later release (#85). |

### 5.3 Incidents

No data-loss issue found by search (the repo has few issues). The CHANGELOG records safety fixes: TOCTOU re-verification before delete, system-path protection, restore path traversal validation, "12 security vulnerabilities fixed", confirm default changed to No (#75), dry-run/real-run protected-path mismatch (#78).

---

## 6. PureMac (U)

Source: `PureMac/Services/{ScanEngine,CleaningEngine,SchedulerService}.swift`, `PureMac/Logic/Utilities/{ProviderPaths,FileProtection}.swift`, README, issues.

### 6.1 Safety mechanisms

| Mechanism | Detail |
|---|---|
| Delete semantics | README: dashboard/category cleanup, scheduled auto-clean, Trash emptying, Docker/Xcode runtime cleanup and admin-authorized removal are **permanent**; app uninstall, orphan removal, duplicates and device backups use the **Trash**. XcodeBuildMCP DerivedData is Trash-only. |
| Allow-list | `isSafeToDelete` allows only resolved paths under a fixed root list: `~/Library/{Caches,Logs,Saved Application State,HTTPStorages,WebKit,Containers,Group Containers,Application Support,Preferences,LaunchAgents,Mail Downloads,org.swift.swiftpm,pnpm/store}`, `~/Library/Developer/{Xcode/DerivedData,Xcode/Archives,CoreSimulator/Caches,Xcode/{iOS,watchOS,tvOS} DeviceSupport,XCTestDevices,Xcode/UserData/Previews}`, `~/.Trash`, `~/.npm`, `~/.pnpm-store`, `~/.cache`, `~/.local/share/pnpm/store`, `~/Library/Containers/com.docker.docker`, `~/.docker/{cli-plugins/.cache,buildx/cache}`, `~/.orbstack/log`, `/Library/{Caches,Logs}`, `/opt/homebrew/Library/Caches`, `/usr/local/Homebrew/Library/Caches`, `/private/var/{log,tmp}`, `/private/tmp`. Downloads, Documents and Desktop are **not** whole-subtree roots (large files are per-file items). AI app targets must match an exact path list. |
| Symlinks / TOCTOU | Resolve symlinks, require the resolved path to equal the original, re-resolve immediately before delete. Admin escalation re-validates every path and refuses symlinks. |
| SIP | `FileProtection`: skips paths with `SF_RESTRICTED`/`SF_IMMUTABLE`/`UF_IMMUTABLE` or the `com.apple.rootless` xattr; records them as "protected", not errors, and does not escalate. |
| Cloud / iCloud | **`ProviderPaths` hard denylist** (issue #142): `~/Library/Mobile Documents`, `~/Library/CloudStorage`, `~/Library/Application Support/{FileProvider,CloudDocs}`, `~/Library/Daemon Containers`, `~/Library/Caches/{CloudKit,com.apple.bird,com.apple.cloudkit,com.apple.cloudd,com.apple.FileProvider}`; any path component `com~apple~*`; checked on both literal and symlink-resolved forms (with Desktop and Documents sync on, `~/Desktop` resolves into iCloud). |
| Privilege escalation | One AppleScript "with administrator privileges" prompt for the batch; paths passed NUL-separated to `xargs -0 rm`; survivors verified by re-stat and inode comparison (daemons recreate logs). |
| Selection defaults | Each item has `isSelected`. Defaults off: HTTPStorages (live sessions), AI chat history, large files, TM snapshots, simulator runtimes, XcodeBuildMCP DerivedData, language files, universal binaries. Per the #144 reply, scheduled cleaning skips items that start unselected (stated for universal binaries and language files). |
| Exclusions | User can exclude paths (right-click); exclusions protect containing folders and apply to scheduled runs. Large-file scan also takes excluded folders. |
| Running apps | No general process or open-file check was found in `CleaningEngine`; Xcode-related guard is the XcodeBuildMCP lifecycle lock *(not exhaustively verified)*. |
| Env hijack hardening | `brew --cache` is run with `HOMEBREW_*` stripped, and the result must be under known cache roots. Bug from [#48](https://github.com/momenbasel/PureMac/issues/48). |
| Dry-run | CLI `puremac clean dev --dry-run`; GUI shows a review list. |

### 6.2 Targets (`ScanEngine.swift`)

| Category | Path / command | sudo | Default selection | Notes |
|---|---|---|---|---|
| System Junk | `/Library/Caches`, `/Library/Logs`, `/private/var/log`, `~/Library/Logs`, `/tmp`, `/private/var/tmp` (recursive, depth 3) | yes (admin second pass for root-owned) | on | |
| User Cache | each child of `~/Library/Caches` except Homebrew, `com.electron.ollama`, `ollama`, `npm`, `Yarn`, `dev.kdrag0n.MacVirt` and provider roots | no | on | |
| User Cache | `~/.cache/pip`, `~/Library/Caches/pip` | no | on | |
| User Cache | `~/Library/Containers/*/Data/Library/Caches`, `~/Library/Group Containers/*/Library/Caches` (>= 1 MB, symlink-checked) | no | on | |
| User Cache | `~/Library/HTTPStorages/*` | no | **off** | Cookies and HSTS state of native apps. |
| AI Apps | `~/.ollama/logs`, `~/Library/Caches/ollama`, `~/Library/Caches/com.electron.ollama`, `~/Library/WebKit/com.electron.ollama`, `~/Library/Saved Application State/com.electron.ollama.savedState`, `~/.lmstudio/server-logs` | no | on | `~/.ollama/history` and `~/.lmstudio/conversations` are listed but **off**. Models untouched. |
| Mail Attachments | `~/Library/Mail Downloads`, `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads` (depth 3) | no | on | |
| Trash | `~/.Trash` (top level) | no | on | |
| Large Files | files in `~/Downloads`, `~/Documents`, `~/Desktop` above threshold (default 100 MB) and older than 12 months (both user-adjustable) | no | **off** | Hidden files skipped by default; excluded folders honoured. |
| Purgeable | APFS purgeable space via `diskutil apfs purgePurgeable /` (virtual item, empty path) | no | on | Issue #112: root path was rendered as the target. |
| Time Machine local snapshots | listed from `tmutil listlocalsnapshots /` with size from `diskutil apfs listSnapshots` | yes | **off** | Confirmation required. |
| Xcode Junk | `~/Library/Developer/Xcode/DerivedData`, `.../Archives`, `~/Library/Developer/CoreSimulator/Caches`, `~/Library/Caches/com.apple.dt.Xcode`, `.../Xcode/{iOS,watchOS,tvOS} DeviceSupport`, `~/Library/Developer/XCTestDevices`, `.../Xcode/UserData/Previews`, `~/Library/Caches/org.swift.swiftpm`, `~/Library/org.swift.swiftpm` | no | on | Archives are selected by default. |
| Xcode Junk | simulator runtimes via `xcrun simctl runtime list -j` / `runtime delete <id>` | no | **off** | Always opt-in. |
| Xcode Junk | XcodeBuildMCP / MobileBuildMCP DerivedData | no | **off** | Lifecycle lock plus age guard when scheduled. |
| Homebrew | `~/Library/Caches/Homebrew`, `/opt/homebrew/Library/Caches`, `/usr/local/Homebrew/Library/Caches`, `/Library/Caches/Homebrew` | no | on | |
| Node caches | npm, Yarn, pnpm cache roots reported by the tool and validated against approved roots (searches `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.volta/bin`, `~/.nvm/versions/node`) | no | on | |
| Docker | `~/Library/Containers/com.docker.docker/Data/{cache,log,tmp}`, `~/Library/Group Containers/group.com.docker/Caches`, `~/.docker/cli-plugins/.cache`, `~/.docker/buildx/cache`, `~/.orbstack/log`, `~/Library/Caches/dev.kdrag0n.MacVirt`, `~/Library/Logs/OrbStack`; virtual item `docker system prune -f` | no | on | `prune -f` without `-a`: tagged images and running containers survive. |
| Universal Binaries | thin `/Applications` apps via `lipo` plus re-sign | no | **off** | See issue #144. |
| Language Files | `/Applications` and `~/Applications` `.lproj` via staged re-sign flow | no | **off** | See issue #144. |
| Device backups | `~/Library/Application Support/MobileSync/Backup` | no | **off** | Manual review, Trash, re-checks for change/symlink/exclusion. |

### 6.3 Incidents (all closed)

| Issue | What happened | Fix |
|---|---|---|
| [#48](https://github.com/momenbasel/PureMac/issues/48) (2026-04) | Zero-click chain: `HOMEBREW_CACHE` env redirected a delete into `~/Documents`, which was a whole-subtree allow-listed root; a pre-seeded schedule plist ran it unattended | v2.1.0: strip `HOMEBREW_*` env, known-roots check, removed Documents/Downloads/Desktop as roots |
| [#51](https://github.com/momenbasel/PureMac/issues/51) (2026-04) | Uninstalling the Claude.ai web app removed `~/.claude` (Claude Code CLI state) by name matching | v2.1.0: stop scanning bare `$HOME` dot-files, three defence layers |
| [#142](https://github.com/momenbasel/PureMac/issues/142) (2026-07) | Cleanup corrupted iCloud Drive File Provider metadata (513 of 19,693 files inconsistent; Finder copies slowed to tens of seconds) | v2.9.5: `ProviderPaths` denylist on scan and delete. Persistent history and rollback did *not* ship |
| [#144](https://github.com/momenbasel/PureMac/issues/144) (2026-07) | "Corrupts applications on default settings": Cursor, GitKraken, JetBrains Toolbox, Figma, Keka, Ableton Live, Stats stopped working | v2.9.5: universal-binary and language-file removal had been protected only in the scheduler; "select all in category" bypassed it. Both modify the bundle and re-sign ad hoc (`codesign --force --deep --sign -`), which breaks sealed resources |
| [#95](https://github.com/momenbasel/PureMac/issues/95), [#112](https://github.com/momenbasel/PureMac/issues/112) | "Couldn't clean everything" false alarms (MS Office package, purgeable item with `/` path) | SIP/immutable results recorded as "protected", purgeable made a virtual item |

---

## 7. MacSai (X)

Source: `Sources/MacCleanKit/{Constants,SafetyGuard,CleanupSelectionPolicy,Categories/*,Models/ScanCategory}.swift`, `Sources/MacClean/Core/Cleaner/CleaningEngine.swift`, README, issues.

### 7.1 Safety mechanisms

| Mechanism | Detail |
|---|---|
| Delete semantics | **Trash-first** with a "Clean History" (last 30 days, up to 20 cleans) and one-click Restore; permanent and dry-run modes exist in the engine. |
| `SafetyGuard` (validates every path before touching it) | Rejects empty/NUL paths; resolves symlinks and canonicalises `/private/{var,tmp,etc}` firmlinks; blocks `/System` (SIP message) and protected prefixes `/System /usr /bin /sbin /Library/Apple /private/var/db` (and others in `MCConstants.protectedPaths`); user-excluded folders; **symlink redirect** if the first 3 path components change after resolution (TOCTOU). Cap of 10,000 files per operation and 500,000 per clean run. |
| Selection policy | Each category has `autoSelect` and a `cleanupSafety` badge (`regenerates`, `safeToRemove`, `reviewFirst`). Not pre-checked: unusedDiskImages, largeFiles, oldFiles, duplicates, projectJunk, universalBinaries, appLeftovers, deletedUsers, packageManagerCaches, ideCaches, aiToolCaches, possibleThreats. Global buttons never add review-only or possible-threat results. |
| Running apps | Running-app check plus a browser profile lock check (Chromium `SingletonLock` symlink, Firefox `.parentlock`): if either says in use, no delete. |
| Folder exclusions | User-defined folder exclusion list (issue #141) enforced inside `SafetyGuard`. |
| Own logs | `~/Library/Logs/MacClean` excluded from log cleaning. |

### 7.2 Targets

| Category | Path / rule | sudo | Default selected | Safety badge |
|---|---|---|---|---|
| User Cache Files | `~/Library/Caches` recursive; excludes `com.spotify.client`, `org.gradle`, Homebrew and pip caches | no | yes | regenerates |
| System Cache Files | `/Library/Caches` recursive | not verified | yes | regenerates |
| User Log Files | `~/Library/Logs` files with extension `log txt crash diag ips` | no | yes | safeToRemove |
| System Log Files | `/Library/Logs` (`log txt crash diag`), `/var/log` (`log gz`) | not verified | yes | safeToRemove |
| Language Files | `/Applications/**/*.lproj` except preferred languages | not verified | yes | reviewFirst |
| Document Versions | `~/.DocumentRevisions-V100` older than 4 hours | no | yes | reviewFirst |
| Broken Downloads | `~/Downloads/*.download\|*.crdownload\|*.part\|*.partial` | no | yes | safeToRemove |
| iOS Device Backups | `~/Library/Application Support/MobileSync/Backup/*` older than 30 d | no | yes | reviewFirst |
| Old Updates | `.pkg`/`.mpkg` under `~/Library/Application Support` (depth 3) older than 7 d | no | yes | safeToRemove |
| Unused Disk Images | `~/Downloads/*.dmg\|*.iso\|*.sparseimage` older than 7 d | no | **no** | reviewFirst |
| Incomplete Downloads | `~/Downloads/*.download\|*.crdownload\|*.part\|*.partial\|*.tmp`; `$TMPDIR` older than 24 h, depth 2 | no | yes | safeToRemove |
| Xcode Junk | children of `~/Library/Developer/Xcode/DerivedData`, `.../Archives`, `.../iOS DeviceSupport`, `~/Library/Developer/CoreSimulator` (all of it, so including `Devices` *(as read)*), `.../Xcode/UserData/Previews` | no | yes | reviewFirst |
| Package Manager Caches | `~/.npm/_cacache`, `~/.cargo/registry/{cache,src}`, `~/.gradle/{caches,daemon,wrapper/dists}`, `~/Library/Caches/Homebrew`, `~/Library/Caches/pip` | no | **no** | regenerates |
| IDE Caches | Cursor and Antigravity Electron cache dirs only (not `User/` or extensions) | no | **no** | regenerates |
| AI Tool Caches | `~/.claude/{cache,paste-cache,shell-snapshots}`, `~/.codex/{.tmp,cache}` (never history, sessions, memory, projects) | no | **no** | regenerates |
| Mail Attachments | `~/Library/Mail Downloads` | no | yes | reviewFirst |
| Trash Bins | `~/.Trash` and volume trashes | no | yes | reviewFirst |
| App Leftovers, Deleted Users, Broken Preferences, Broken Login Items | orphan scans (Deleted Users flags `/Users/<name>` absent from `dscl . -list /Users`) | no | **no** (leftovers/users) | |
| Project Junk | `node_modules`, `.next`, `dist` (need a Node marker sibling), `target`, `build` (need Gradle marker) and similar, only when sibling files confirm the project type | no | **no** | reviewFirst |
| Browser / System Privacy | history and tracking data; recent-item lists (cookies and sessions kept) | no | yes | reviewFirst |
| Universal Binaries | Mach-O slice thinning (`lipo`, never re-signs) | not verified | **no** | reviewFirst |
| Large/Old Files, Duplicates | review-only | no | **no** | reviewFirst |

### 7.3 Incidents

None found via issue search for data loss. Issues #159 and #164 (closed) are about false "freed" totals and thinning that reported success when nothing was thinned. Note that `iosDeviceBackups` (older than 30 d), `documentVersions`, `languageFiles`, `xcodeJunk` and `trashBins` are pre-selected despite a `reviewFirst` badge *(from `autoSelect` as read)*.

---

## 8. Cross-tool safety comparison and what the incidents imply

| Safety feature | M | P | S | C | U | X |
|---|---|---|---|---|---|---|
| Dry-run | yes, same predicates as real run | yes, size estimate only | yes, size estimate only | yes (protected check before dry-run return) | yes (GUI review; CLI `--dry-run`) | yes (engine mode) |
| Trash instead of permanent delete for cleaning | no (permanent) | no | no | opt-in backup folder (7 d) | no for categories; yes for uninstall/orphans/duplicates/backups | **yes by default**, with restore history |
| Allow-list of roots vs deny-list only | both (deny list, protected globs, explicit allow inside `/private`) | prefix deny list (bypassed by globs) | none | deny list + `/tmp` exception | **allow-list of roots** + provider denylist | deny list + category targets |
| Skips running apps | per-app process + lsof + SQLite checks | kills chosen apps instead | no | no | no (not found) | running-app + profile-lock checks |
| Age thresholds | many (1 d to 30 d) | none | none | 30 d (downloads, node_modules), 7 d (worktrees) | user-set for large files | 4 h, 24 h, 7 d, 30 d on some categories |
| Symlink / TOCTOU defence | ancestor-symlink check + inode identity bound at sink | none | none | lstat re-check, unlink symlinks | resolve-and-compare twice | resolve + first-3-components check |
| SIP handling | deny list only | prefixes + rootless xattr (not for globs) | none | prefix list | flags + rootless xattr, no escalation | `/System` check |
| iCloud / File Provider | `~/Library/Mobile Documents*` protected by default | none | none | none | **hard denylist** incl. CloudKit/bird caches | `Mobile Documents` not specifically listed |
| Photos library | untouched | untouched | untouched | untouched | untouched | untouched |
| Mail | `~/Library/Mail` protected; Mail Downloads with edit-detection | logs only | logs only | Mail Downloads (risky, opt-in) | Mail Downloads | Mail Downloads |
| Messages | previews and stickers only | no | no | no | no | no |
| Operation log | yes | no | no | `MAC_CLEANER_DEBUG` | yes (Logger) | yes (clean history) |
| Sudo | self-escalates only for System section | none for paths, hard-coded for 2 commands | `sudo -v` always | `sudo -n` for maintenance only | admin prompt for batch | not verified |

Rules the incidents add up to (for the TruongCleaner design, not copied from any code):

1. **A cache-shaped path can hold live state.** Examples: `~/Library/Caches/CloudKit`, `com.apple.bird`, `FileProvider` (iCloud sync database), Kitty graphics cache, `pypoetry/virtualenvs`, renv, `pnpm/dlx`, `llama.cpp` model weights, Telegram `postbox/db`, HTTPStorages cookies, `~/.claude/projects/*/memory`. Prefer an explicit allow-list with a protected overlay over "sweep everything under Caches".
2. **Name matching is not ownership.** Mole #1590/#1670/#993, PureMac #51 and Mole #1446 all came from inferring "this belongs to an uninstalled app" from names. Orphan detection needs bundle-id evidence, an app-inventory scan that fails closed, an age threshold, and a re-check after sizing.
3. **Modifying an app bundle breaks its signature** (PureMac #144, mac-cleaner-cli note). Language-pack and architecture removal should either not exist or be gated behind explicit per-app consent; "select all in category" must not bypass that gate.
4. **Do not delete a directory that macOS or an app expects to exist** (Mole #1689 `DiagnosticReports`, #1854 `kitty`). Delete children; keep the container.
5. **Check liveness at the delete boundary, not just at scan time**: running owner process, open file handles (including SQLite WAL families), mtime, and parent/target identity. Treat "unknown" as "keep" (Mole's pattern: timeout, unreadable plist, unreadable mtime, `tmutil status` unknown).
6. **Environment variables and CLI output are untrusted delete targets** (PureMac #48 `HOMEBREW_CACHE`; P and S trust `brew --cache` and `PYENV_VIRTUALENV_CACHE_PATH`). Validate against known roots and strip env before invoking.
7. **Delegate to owner commands when one exists** (`brew cleanup`, `docker image prune`, `go clean`, `npm cache clean`, `simctl`, `tmutil`) and never prune Docker volumes.
8. **Dry-run must run the same eligibility predicates** as the real run (Mole, mac-cleaner-cli #78, P #279 contrasts).
9. **SIP is not detected by most tools.** Only PureMac and mac-cleanup-py read `com.apple.rootless`/flags. A native Swift app can use `lstat` flags (`SF_RESTRICTED`, `SF_IMMUTABLE`) and treat them as "protected, not an error".
10. **Review-only is a legitimate tier**: Mole keeps Xcode Archives, Gradle `caches`, Maven `.m2`, NuGet, simulator runtimes, iOS backups, JetBrains old-version data, model stores and Docker Desktop data as report-only rows, after earlier versions deleted some of them.

Disagreements worth a deliberate decision:

| Item | Delete | Review-only / skip |
|---|---|---|
| Xcode Archives | P, S, C, U, X | M (dSYM concern, #756) |
| `~/.gradle/caches` | P, S, C, X | M (default-whitelisted, shown as review) |
| `~/.m2/repository` | none | M |
| iOS device backups | P, S (auto), X (auto-selected, 30 d), C (risky opt-in) | M (review), U (manual review via Trash) |
| Entire `~/Library/Caches/*` | P, S, X | M, U, C use exclusion lists and guards |
| Whole `~/.cargo/registry` incl. `src` | C, X | M (keeps `src`, `index`, `git`) |
| Docker | M (dangling + builder > 7 d), U (`prune -f`), C (images + containers + builder with `-a`), P/S (`prune -af`) | volumes: never in M, U, C |
| `.lproj` language packs | C, U, X (all flag it as signature-breaking/risky) | M (no language-pack cleaner in `clean`) |
| Time Machine local snapshots | C (`deletelocalsnapshots`, asks), U (opt-in, confirmation) | M (report only) |

---

## 9. Unified target catalog

Codes: **M** Mole, **P** mac-cleanup-py, **S** mac-cleanup-sh, **C** mac-cleaner-cli, **U** PureMac, **X** MacSai. "Stance" summarises what the tools do; `del` = deletes by default, `opt` = opt-in/unselected, `rev` = report only, `owner` = delegated to the tool's own command. Paths use `~` for the user home. Age values are from the tool named.

### 9.1 User caches

| Target | Path / glob | Tools | Stance and notes |
|---|---|---|---|
| All per-app caches | `~/Library/Caches/*` (children) | M U X C P S | del. M/U/X/C use exclusions; P prompts; S none. M excludes `Google` (handled after Chrome quits), Deno root, hard-whitelist (FontRegistry, spotlight, CloudKit, kitty, pypoetry/virtualenvs, renv, pnpm/dlx, llama.cpp), live-owner and SQLite checks. U excludes provider roots (CloudKit, bird, cloudd, FileProvider). |
| Sandbox app caches | `~/Library/Containers/*/Data/Library/Caches/*` | M U | del. M skips Apple-critical/data-protected ids, symlinks; U needs >= 1 MB and unchanged resolved path. |
| Sandbox temp | `~/Library/Containers/<id>/Data/tmp/*` | M (explicit ids only) | del. |
| Group container caches/logs | `~/Library/Group Containers/*/Library/Caches` (non-Apple), `.../Logs`, `.../Library/Logs` | M U | del. Skip `com.apple.*`/`group.com.apple.*`/`systemgroup.com.apple.*`; skip Safari Web Extension containers; skip unreadable (TCC). |
| Named Apple caches | `~/Library/Caches/com.apple.{photoanalysisd, akd, WebKit.Networking, QuickLook.thumbnailcache, iconservices*, helpd, AppleMediaServices, duetexpertd, parsecd, python, rosetta.update, amp.mediasevicesd, mail}`; `~/Library/Caches/Quick Look`, `GeoServices`; `~/Library/{IdentityCaches,Suggestions}`; `~/Library/Application Support/AddressBook/Sources/*/Photos.cache` | M | del. Protected (never): `containermanagerd`, `homed`, `HomeKit`, `adprivacyd`, `FamilyCircle`, Shortcuts sandbox caches, `com.apple.finder`, `FontRegistry`, `spotlight`, CoreAudio caches. |
| Apple sandbox container ids | `com.apple.{mediaanalysisd, AppStore, configurator.xpc.InternetService, wallpaper.extension.aerials, geod, stocks, AvatarUI.AvatarPickerMemojiPicker, AMPArtworkAgent, CoreDevice.CoreDeviceService, NeptuneOneExtension, AppleMediaServicesUI.UtilityExtension}` | M | del (explicit list). |
| Saved application state | `~/Library/Saved Application State/*` | M U (allowed root) ; M optimize 30 d | del. |
| Per-app HTTP storage | `~/Library/HTTPStorages/*` | U | opt (live sessions). M's orphan sweep previously touched these (Mole Mac #1670) and now does not. |
| Wallpaper renders | `~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/**/*.bmp` | M | del, newest kept. |
| Handoff clipboard | `~/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/*` older than 60 min | M | del. |
| Recent items | `~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.Recent{Applications,Documents,Servers,Hosts}.sfl[2]`; `~/Library/Preferences/com.apple.recentitems.plist` | M (X "System Privacy" category) | del (M); X reviewFirst. |
| Generic Application Support caches | `~/Library/Application Support/<app>/{Code Cache,GPUCache,DawnCache,GrShaderCache,GraphiteDawnCache,DawnGraphiteCache,DawnWebGPUCache,Crashpad/completed}` (and `Cache`, `CachedData` with markers) | M | del when app not running. |
| Misc app support junk | `~/Library/Application Support/CrashReporter/*` > 30 d | M | del. |
| Analyzer/tool-own cache | `~/.cache/mole/*.cache` | M | del. |
| Rosetta/media service | `~/Library/Caches/com.apple.rosetta.update`, `/Library/Apple/usr/share/rosetta/rosetta_update_bundle` | M | del; the second is likely refused by Mole's own `/Library/Apple` deny rule. |

### 9.2 System caches and temp

| Target | Path | Tools | Stance and notes |
|---|---|---|---|
| System caches | `/Library/Caches` | M (files `*.cache\|*.tmp\|*.log` > 7 d, depth 5) U X S | del, sudo. S/X/U take everything; M only aged files. |
| SIP cache dir | `/System/Library/Caches/*` | S | del attempted; fails under SIP. Not recommended. |
| Per-user Darwin cache | `/private/var/folders/<xx>/<yy>/C/**` | S P (`bh` shard only) | del. |
| Metal/GPU shader caches | `/private/var/folders/*/*/C/*/com.apple.{gpuarchiver,metal,metalfe}` | M | gated: idle >= 1 d; skip EDR vendors. |
| Per-user temp | `/private/var/folders/*/*/T/*` | C | del. M deliberately excludes it. |
| `/tmp`, `/private/var/tmp` | contents | C U (depth 3) X (`$TMPDIR` > 24 h, depth 2) | del. M refuses ("age and bounded scans do not prove third-party state disposable"). |
| Icon services store | `/Library/Caches/com.apple.iconservices.store` | M | del, sudo. |
| Code-signing clones | `$DARWIN_USER_DIR/../X/<bundle>.code_sign_clone/code_sign_clone.*` | M | gated: browsers idle; skip EDR. |
| Aborted aerial downloads | idleassetsd temp `CFNetworkDownload_*.tmp` > 7 d under `/private/var/folders` | M | del, sudo. Wallpaper/aerial assets in `~/Library/Application Support/com.apple.{idleassetsd,wallpaper}` are protected. |
| macOS installers | `/Applications/Install macOS*.app` | M (>= 14 d, Apple-signed, not current major, no pending update) | gated. Reported as review in the large-file list. |
| Software Update staging | `/Library/Updates`, `/macOS Install Data`, `~/Library/Updates` | M | never (first two); review (third). |
| Xcode docs index | `/Library/Developer/Xcode/DocumentationCache/DeveloperDocumentation*.index` | M | del older ones, keep newest. |
| CoreSimulator system cache | `/Library/Developer/CoreSimulator/Caches/*` | M | del when no simulator active. |
| Diagnostics databases | `/private/var/db/{diagnostics,DiagnosticPipeline,powerlog}` > 7 d; `/private/var/db/reportmemoryexception/MemoryLimitViolations` > 30 d | M | del, sudo; never the active powerlog DB. |

### 9.3 Logs and crash reports

| Target | Path | Tools | Stance and notes |
|---|---|---|---|
| User logs | `~/Library/Logs/*` | M U X C | del. Keep `DiagnosticReports` dir (M); X filters by extension `log txt crash diag ips`; X skips its own log dir; M protects its own `~/Library/Logs/mole`. |
| User crash reports | `~/Library/Logs/DiagnosticReports/*` | M (children only) | del. |
| System logs | `/Library/Logs/*`, `/private/var/log/*` | U X (all) M (`/private/var/log` `*.log\|*.gz\|*.asl` > 7 d) C (`/var/log`, refused) | del, sudo. |
| System crash reports | `/Library/Logs/DiagnosticReports/*` | M (> 7 d) P S | del, sudo. |
| ASL logs | `/private/var/log/asl/*.asl` | P S | del. |
| Adobe logs | `/Library/Logs/{Adobe,CreativeCloud,adobegc.log}` | M (> 7 d) P S | del. |
| Mail logs | `~/Library/Containers/com.apple.mail/Data/Library/Logs/Mail/*` | P S | del. |
| CoreSimulator logs | `~/Library/Logs/CoreSimulator/*` | P S | del. |
| Xcode device logs | `~/Library/Developer/Xcode/iOS Device Logs/*` | P S | del (S has an unquoted-path bug). |
| Crashpad completed | `<browser>/Crashpad/completed/*` | M | del. |
| Crash SDK reports | `~/Library/Caches/{SentryCrash,KSCrash,com.crashlytics.data}/*` | M | del. |
| App Support crash reporter | `~/Library/Application Support/CrashReporter/*` > 30 d | M | del. |
| Java heap dumps | `~/*.hprof` | P S | del (prompt in P). |
| Cloud CLI logs | `~/.config/gcloud/logs/*`, `~/.azure/logs/*` | M | del. |

### 9.4 Trash

| Target | Path | Tools | Stance and notes |
|---|---|---|---|
| User Trash | `~/.Trash/*` | M P S C U X | del; M lets the user whitelist it; needs Full Disk Access to list. Direct delete (M avoids Finder dialog). |
| Volume Trashes | `/Volumes/*/.Trashes/*` | P S X (per README: "every location, including external drives"), U (README) | del. M does not empty volume Trashes. |

### 9.5 Browsers

| Target | Path | Tools | Stance and notes |
|---|---|---|---|
| Safari cache | `~/Library/Caches/com.apple.Safari/*` | M C U(via Caches) X | del. |
| Chrome HTTP cache | `~/Library/Caches/Google/Chrome/*` | M C X | del after quit (M). |
| Chrome profile caches | `~/Library/Application Support/Google/Chrome/<profile>/{Application Cache,Code Cache,GPUCache,DawnCache,GrShaderCache,GraphiteDawnCache}`; root `{ShaderCache,GrShaderCache,GraphiteDawnCache,component_crx_cache,Crashpad/completed}` | M P(`Default/Application Cache` only) S(same) | del when Chrome not running. |
| Chrome AI models | `Chrome/{OptGuideOnDeviceModel,OptGuideOnDeviceClassifierModel,optimization_guide_model_store}` | M | del; whitelist-able. |
| Chrome updater | `~/Library/Application Support/Google/GoogleUpdater/{crx_cache,*.old}` | M | del. |
| Chromium-family caches | same subfolders for Arc, Dia, Brave, Helium, Yandex, Vivaldi, QQBrowser, BrowserOS, Chromium, Edge, Opera, Orion, Zen, Comet | M (broad) P (Chromium, Arc) C (Arc, Chrome, Firefox, Safari) | del when not running. |
| Firefox | `~/Library/Caches/Firefox/*`, `~/Library/Application Support/Firefox/Profiles/*/cache2/*` | M C(`Caches/Firefox/Profiles`) X(privacy) | del; **never the profile directory**. |
| Service worker CacheStorage | `<profile>/Service Worker/CacheStorage` | M | del, but skip PWA-critical domains (Google Docs/Drive/Mail, GitHub, GitLab, Notion, Figma, Linear and so on). |
| Old browser app versions | `<Browser>.app/Contents/Frameworks/*.framework/Versions/<old>` (Chrome, Edge, Brave) | M | del, keep `Current`. |
| Browser history / cookies | Arc `History`, `Cookies`, `Web Data` | P | del (privacy wipe, not cache). X "Browser Privacy" clears history and tracking data, keeps cookies and sessions. |
| Code-sign clones | see 9.2 | M | gated. |
| Puppeteer cache | `~/.cache/puppeteer/*` | M | del. `ms-playwright` is hard-protected. |
| Leaked automation profiles | temp profiles of orphaned Playwright/Puppeteer/DevTools-MCP browsers | M | gated by PID + start-time match. |

### 9.6 App-specific caches (third-party)

| Group | Targets | Tools | Stance |
|---|---|---|---|
| Messaging / meetings | Zoom, WeChat, Telegram (cache only in M), Teams, WhatsApp, Skype, QQ, Tencent Meeting, WeCom, Feishu, DingTalk, ChatGPT, Claude Desktop | M (Teams classic app data also P S) | del. P/S Teams path wipes IndexedDB/Local Storage (signs out). P Telegram deletes `postbox/db`: high risk. |
| Creative / video / 3D | Sketch, Figma, ScreenFlow, Final Cut Pro, DaVinci Resolve (+ `~/Movies/CacheClip`), Premiere Pro, Fusion 360, Blender, Cinema 4D, SketchUp, Adobe Media Cache (`~/Library/Application Support/Adobe/Common/Media Cache Files/*`) | M P S (Adobe only) | del. Adobe `Library/Caches/Adobe*` is protected in M. |
| Media players | Apple Music/Podcasts/TV, Plex, IINA, VLC, MPV, NetEase, QQ Music, Kugou, Kuwo, iQIYI, Bilibili, Stremio, Tencent Video | M | del. |
| Games | Steam (`appcache`, `depotcache`, `logs`, `shadercache`, `htmlcache`; P/S also `steamapps/temp` and `steamapps/download`), Epic, Battle.net, EA (`EA app/{IGOCache,Logs,OfflineCache,CEF/...}` in P), GOG, Riot, Minecraft (`logs`, `crash-reports`, `webcache*`), Lunar Client, PCSX2, RPCS3 | M P S | del. `steamapps/download` can hold partial games. |
| Notes / productivity | Notion, Obsidian (cache subfolders only; `Cache`, `Code Cache`, `DawnGraphiteCache`, `DawnWebGPUCache`, `*.log`), Logseq, Bear, Evernote, Alfred, Todoist, Spark, Airmail | M P (Obsidian) | del. |
| Cloud sync | Dropbox (`~/Library/Caches/com.dropbox.*`; P/S `~/Dropbox/.dropbox.cache/*`), Google Drive (`~/Library/Caches/com.google.GoogleDrive`; P/S `DriveFS/*/content_cache`), OneDrive (`~/Library/Caches/com.microsoft.OneDrive`), Box, Baidu | M P S | del when the sync client is not running. `~/Library/CloudStorage`, `Mobile Documents` never touched by M/U. |
| Office | Word/Excel/PowerPoint/Outlook caches and container tmp/logs, iWork, WPS, Thunderbird | M | del when app closed. |
| Terminals / CLIs | Warp, Ghostty, Kaku, `~/.zcompdump*`, `~/.lesshst`, `~/.viminfo.tmp`, `~/.wget-hsts`, Oh My Zsh cache | M (P S: wget) | del. |
| Remote / utilities | TeamViewer, AnyDesk, ToDesk, CleanShot, Xnip, The Unarchiver | M | del. |
| Virtualisation | UTM, VMware Fusion, Parallels, VirtualBox `.cache`, Lima download cache, Vagrant tmp, Tart | M | del; VM disks never touched. |
| JetBrains logs | `~/Library/Logs/JetBrains/*` | M P S | del. JetBrains caches and per-version data: default-protected in M. |
| VS Code family | `~/Library/Application Support/Code/{Cache,CachedData}`, Cursor/Antigravity Electron caches | M (menu rows) X (Cursor, Antigravity) | del / opt. |

### 9.7 Developer tools

| Target | Path / command | Tools | Stance and notes |
|---|---|---|---|
| Xcode DerivedData | `~/Library/Developer/Xcode/DerivedData/*` | M P S C U X | del. M skips while Xcode/xcodebuild run; U treats XcodeBuildMCP DerivedData as opt-in. |
| Xcode Archives | `~/Library/Developer/Xcode/Archives` | P S C U X | del in 5; **rev in M** (dSYMs). |
| Xcode DeviceSupport | `~/Library/Developer/Xcode/{iOS,watchOS,tvOS,macOS,visionOS,xrOS} DeviceSupport` | M (keep 2 newest) U X (iOS only) | del. |
| Xcode previews / IB | `~/Library/Developer/Xcode/UserData/{Previews,IB Support}` | U X (Previews) M (IB Support) | del. |
| Xcode internal cache | `~/Library/Caches/com.apple.dt.Xcode` | M U | del. |
| XCTest devices | `~/Library/Developer/XCTestDevices/*` | M U | del. |
| Simulators (state) | `xcrun simctl erase all` | P S | del (wipes every device). |
| Simulators (unavailable) | `xcrun simctl delete unavailable` | M | del. |
| Simulator devices dir | `~/Library/Developer/CoreSimulator/Devices` | M (rev) X (via CoreSimulator children, *as read*) | disagreement. |
| Simulator runtimes | `xcrun simctl runtime delete <id>` | U (opt) M (rev orphan list) | opt/rev. Runtime volume roots under `/Library/Developer/CoreSimulator` are Apple-owned and never touched by M. |
| Simulator caches | `~/Library/Developer/CoreSimulator/Caches`, `/Library/Developer/CoreSimulator/Caches/*`, `.../Profiles/Runtimes/*/.../System/Library/Caches/*` | U M | del. |
| Swift Package Manager | `~/Library/Caches/org.swift.swiftpm`, `~/.cache/swift-package-manager`, `~/Library/org.swift.swiftpm` | M U | del. |
| Homebrew | `brew cleanup` (`-s`, `--prune=30`, or `--prune=all`); cache dirs `~/Library/Caches/Homebrew`, `/opt/homebrew/Library/Caches`, `/usr/local/Homebrew/Library/Caches` | M P S C U X | owner. Validate `brew --cache`. `brew autoremove` rev only (M). |
| npm | `npm cache clean --force`; `~/.npm/_cacache`, `_logs`, `_prebuilds` (not `_npx`) | M P S C U X | owner/del. |
| Yarn | `~/Library/Caches/Yarn`; `yarn cache clean --force` | M P S C U | owner/del. Berry `~/.yarn/berry/cache` protected (M). |
| pnpm | `~/Library/pnpm/store`, `~/.pnpm-store`, `~/.local/share/pnpm/store`; `pnpm store prune`; `pnpm/dlx` protected | M P S C U | owner. M also lists the store as rev. |
| Bun | `bun pm cache rm`; `~/.bun/install/cache` | M P | owner. |
| pip / Python | `pip3 cache purge`; `~/.cache/pip`, `~/Library/Caches/pip`; `~/.pyenv/cache`; Poetry caches (not venvs in M); `~/.cache/uv`; `~/.cache/{ruff,mypy}`, `~/.pytest_cache`; conda `--index-cache --tarballs --logfiles`; PyInstaller bincache | M C U X (pip) P S (Poetry, pyenv-virtualenv) | del/owner. Poetry `virtualenvs` are protected in M, deleted by P and S. |
| Cargo / Rust | `~/.cargo/registry/cache`, `~/.rustup/downloads` | M (cache only) C X (+ `src`) | del. |
| Go | `go clean -modcache`, `go clean -cache` | M P S | owner. |
| Gradle | `~/.gradle/caches`, `daemon`, `wrapper/dists`, `build-cache-*` | P S C X M(off) | M ships it default-whitelisted and shows review. |
| Maven / Ivy / NuGet / sbt | `~/.m2/repository`, `~/.ivy2/cache`, `~/.nuget/packages`, `~/.sbt` | P (NuGet, prompted) | rev in M; del only in P. |
| CocoaPods | `pod cache clean --all`; `~/Library/Caches/CocoaPods` | P S C | M disabled the delete. |
| Ruby | `gem cleanup`; `~/.gem/{specs,ruby/*/cache}`, `~/.bundle/cache`, `~/.rbenv/cache` | M P S | owner/del. |
| PHP Composer | `composer clearcache`; `~/.composer/cache`, `~/Library/Caches/composer` | M P S | owner/del. |
| Deno / mise / corepack / Dart / Flutter / Haskell | Deno cache (root kept), mise cache clear, corepack home; Dart pub and Flutter caches disabled; Stack/cabal untouched | M | del/off. |
| Docker / OCI | `docker image prune -f` (dangling), `docker builder prune --filter until=168h`, `docker system prune -f\|-af`, `~/.docker/buildx/cache`, `~/Library/Containers/com.docker.docker/Data/{cache,log,tmp}`, `~/Library/Group Containers/group.com.docker/Caches`, `~/.orbstack/log`, Podman `~/.local/share/containers/storage/tmp` | M P S C U | owner. Volumes: never in M/U/C. Docker Desktop data dir: rev (M). |
| Nix | `nix-store --gc` | M | owner. |
| Kubernetes / cloud CLIs | `~/.kube/cache`, `~/.aws/cli/cache`, `~/.cache/terraform`, `~/.grafana/cache` | M | del. |
| JS toolchain caches | `~/.cache/{typescript,electron,node-gyp,vite,webpack,eslint,prettier,prisma,pre-commit,curl,wget}`, `~/.node-gyp`, `~/.turbo/cache`, `~/.vite/cache`, `~/.parcel-cache`, Corepack | M | del. |
| Build/CI | `~/.cache/bazel`, `~/.cache/zig`, `~/.cache/gitlab-runner`, `~/.jenkins/workspace/*/target`, `~/.github/cache`, `~/.circleci/cache`, `~/.sonar` | M | del. |
| Expo / React Native | `~/.expo/*-cache` (not `state.json`) | M | del. |
| Android | `~/.android/{cache,build-cache}`, `~/Library/Caches/Google/AndroidStudio*`; AVDs, system images, SDK NDK versions | M P S (cache) | del for caches; rev for AVDs/images. |
| JetBrains Toolbox | old IDE builds (keep 1), old per-version dirs | M | del builds; rev per-version config dirs. |
| API / DB clients | Postman, Insomnia, TablePlus, Sequel Ace/Pro, Navicat, DBeaver, RedisInsight, Charles, Proxyman, MongoDB Compass | M | del. |
| AI coding agents | old CLI versions (`~/.local/share/claude/versions`, `cursor-agent`, `~/.copilot/pkg/universal`, Claude Desktop bundled code, Codex runtimes/releases/staging) | M | del, keep active + 1 previous. |
| AI agent caches | `~/.claude/{cache,paste-cache,shell-snapshots}`, `~/.codex/{.tmp,cache}`, Antigravity/Gemini/DevTools-MCP Chromium cache dirs | X (opt), M (partial) | del/opt. Sessions, memory, auth, history **never** (M protected, X never targeted). |
| Local LLM data | `~/.ollama/logs`, Ollama/LM Studio caches, `~/.lmstudio/server-logs` | U (on) | del. `~/.ollama/history`, `~/.lmstudio/conversations`: U opt; models: M protects `~/.ollama/models`, shows `~/.lmstudio/models` and Hugging Face as rev. |
| Project artifacts | `node_modules`, `.next`, `dist`, `target`, `build`, `.venv`, `__pycache__`, `Pods`, `.build`, `.dart_tool`, `coverage`, `.gradle`, … in project folders | M (`mo purge`; `clean` hints only; `__pycache__`, `.next/cache`, `.dart_tool` auto, git-tracked kept) C (`node_modules` > 30 d) X (Project Junk, opt) | del after selection. Do not follow into `Library/CloudStorage` without a cloud-sync guard. |
| AI agent worktrees | `<project>/.claude/worktrees`, `~/.codex/worktrees`, `~/.t3/worktrees`, `~/.cursor/worktrees` | M (rev only) C (risky, opt) | rev/opt: may hold uncommitted work. |
| Stale download installers | `.dmg .pkg .mpkg .iso .xip .zip` in Downloads etc. | M (`mo installer`) X (`.dmg .iso .sparseimage` > 7 d; `.pkg .mpkg` in App Support > 7 d) | opt. |

### 9.8 Mail and Messages

| Target | Path | Tools | Stance and notes |
|---|---|---|---|
| Mail attachment copies | `~/Library/Mail Downloads`, `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads` | M (> 30 d, >= 5 MB, untouched copy, Mail closed) C(risky) U X | del/opt. Unedited-copy check is the key safety rule. |
| Mail cache | `~/Library/Caches/com.apple.mail/*` | M | del; whitelist menu row. |
| Mail database | `~/Library/Mail` | M | protected; rev size row. SQLite vacuum only in `optimize`. |
| Messages previews/stickers | `~/Library/Messages/{StickerCache,Caches/Previews/Attachments,Caches/Previews/StickerCache}` | M | del. Message attachments (`~/Library/Messages/Attachments`) never targeted by any tool. |
| Photos library / analysis | `~/Pictures/Photos Library.photoslibrary` | none | not touched by any tool; only `~/Library/Caches/com.apple.photoanalysisd` (M). |

### 9.9 iOS backups, firmware and installers

| Target | Path | Tools | Stance and notes |
|---|---|---|---|
| iPhone/iPad backups | `~/Library/Application Support/MobileSync/Backup/*` | P S (del, no prompt) C (risky opt) X (> 30 d, pre-selected, reviewFirst) U (manual review, Trash) | M: review row with newest-child date. Treat as the user's only backup. |
| Device firmware | `~/Library/iTunes/{iPhone,iPad,iPod,Apple TV} Software Updates/*.ipsw`, `~/Library/Group Containers/*.group.com.apple.configurator/**/*.ipsw` | M | del; open files kept; whitelist rows exist. |
| iOS apps (iTunes) | `~/Music/iTunes/iTunes Media/Mobile Applications/*` | P S | del. |
| macOS installer apps | `/Applications/Install macOS*.app` | M | gated (see 9.2). |

### 9.10 Time Machine, APFS snapshots, purgeable, sleepimage/swap

| Target | Path / command | Tools | Stance and notes |
|---|---|---|---|
| Incomplete TM backups | `<vol>/Backups.backupdb/**/*.inProgress` via `tmutil delete` | M | gated: >= 48 h, TM idle. |
| TM local snapshots | `tmutil listlocalsnapshots /`; `tmutil deletelocalsnapshots <date>` | M (rev) C (delete, asks) U (opt, confirm) | disagreement. M also reports non-TM APFS snapshots (CCC, Synology). |
| APFS purgeable space | `diskutil apfs purgePurgeable /`; `/usr/sbin/purge` | U C (`purge`) | on in U; opt in C. |
| Inactive memory | `sudo purge` | P S | del-like; not disk space. |
| DNS cache | `dscacheutil -flushcache`; `killall -HUP mDNSResponder` | P S C (M in `optimize`) | maintenance, sudo. |
| `/private/var/vm/sleepimage`, swap files | none | **no tool** | SIP-adjacent, system-managed: no tool touches them. Treat as out of scope. |

### 9.11 Language packs and architectures

| Target | Path / command | Tools | Stance and notes |
|---|---|---|---|
| Unused localizations | `/Applications/*.app/Contents/Resources/*.lproj` (keep English, Portuguese, Base in C; user-preferred in X) | C (risky) U (opt, staged re-sign) X | **Breaks code signatures** (C note, U #144). M has no such cleaner. |
| Intel slices in universal apps | `lipo` thinning | M (`slim`, on a copy, keeps AS signature) U (opt) X (opt, no re-sign) | opt. |

### 9.12 Leftovers, orphans, startup items and misc

| Target | Path | Tools | Stance and notes |
|---|---|---|---|
| Orphaned Caches/Logs/Saved State | `~/Library/{Caches,Logs}/{com,org,net,io}.*`, `*.savedState` for uninstalled apps | M (30 d, installed-app inventory, mdfind fallback, never-delete patterns) X (opt) U (opt) | gated/opt. |
| Orphaned system services | `/Library/{LaunchDaemons,LaunchAgents,PrivilegedHelperTools}` entries with missing binaries | M | gated, sudo; vendor-owned MDM/EDR/VPN excluded. |
| Broken LaunchAgents | `~/Library/LaunchAgents/*.plist` with missing program | C (del) M (report) X (Broken Login Items) | disagreement; M reduced it to report after #204. |
| Broken preferences | corrupt plist in `~/Library/Preferences` | M (optimize repairs) X | opt. |
| Empty container stubs | `~/Library/Containers/<id>` (empty) | M (`rmdir`) | gated. |
| Deleted users | `/Users/<name>` not in `dscl . -list /Users` | X (never preselected) | opt. |
| Document revisions | `~/.DocumentRevisions-V100` > 4 h | X | reviewFirst, pre-selected. |
| `.DS_Store` | `$HOME` tree (max 500 per scan), external volumes | M (off by default) | whitelist sentinel `FINDER_METADATA`. |
| Incomplete downloads | `~/Downloads/*.download\|*.crdownload\|*.part` (+`*.partial`, `*.tmp` in X) | M (open-file probe) X | del. |
| Large and old files | files >= 100 MB/500 MB/1 GB in Downloads/Documents/Desktop | U (off) C (risky) X (opt) M (rev rows) | opt/rev. |
| Duplicates | SHA-256 groups | U (Trash) C (risky) X | opt. |
| Spotlight/Quarantine/notifications/CoreDuet | `optimize` tasks | M | maintenance, not cleaning. |

---

## 10. Gaps and caveats

- **Not read:** Pearcleaner, lemon-cleaner, Clean-Me (other worker's scope). Mole's `bin/uninstall.sh`, `bin/slim.sh` and `cmd/` Go code were read only for headline behaviour. The long tail of Mole's app-cache list (about 150 bundle ids) is summarised by group; the exact ids are in `lib/clean/app_caches.sh` of the Mole repo at `6d1af75`.
- **Not executed:** nothing was run. Behaviour statements marked *(as read)* are code inspection only.
- **Moving targets:** Mole commits almost daily (HEAD is dated 2026-11-06) and the incident fixes cited above span 2025-12 to 2026-11. Re-check before treating any row as current.
- **Evidence strength:** Mole, P, S, C: strong (full source of the cleaning path read; incidents from the issue trackers). U and X: moderate (core scan, safety and category files read, not every view model).
- **Licence reminder:** Mole GPL-3.0. Treat this file as the input; write the rule catalog independently.
- **Cleanup:** my clones (Mole, mac-cleanup-py, mac-cleanup-sh, mac-cleaner-cli) are deleted after this file was written. Scratch notes in `work/` are deleted too.
