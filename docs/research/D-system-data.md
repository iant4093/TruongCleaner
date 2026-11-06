# D. What "System Data" is on macOS 15/26/27, and what a third-party cleaner can touch

Prepared 2026-11-06 for TruongCleaner (native macOS, Developer-ID, Swift 6.4).
Content was rephrased for compliance with licensing restrictions. Source IDs (S1, S2, ...) are listed at the bottom.

## 0. Bottom line

1. Apple defines System Data as a residual: whatever the Storage pane cannot assign to another category. Apple states you cannot manage it directly. [S1][S2]
2. The real contributors are about a dozen. In rough order of how often they cause "mystery" hundreds of GB:
   - APFS local snapshots
   - Spotlight index bugs
   - Rosetta cache outliers
   - `/private/var/folders` cache leftovers
   - Docker/VM images
   - Xcode simulator runtimes
   - Apple Intelligence/language assets (14-30 GB on macOS 27)
   - Post-upgrade transients
3. Only a few have an Apple-sanctioned reduction path that a third-party app can drive:
   - Snapshots: via `tmutil` as root.
   - Spotlight: via `mdutil -E` as root.
   - Simulators: via `xcrun simctl runtime delete` as the user.
   - Docker: via `docker system prune` and Docker Desktop's own controls.
   - Caches: via files the user owns.
   - Backups: via Finder or `~/Library/Application Support/MobileSync/Backup`.
4. Nothing third-party can touch on macOS 26/27: AssetsV2 (Apple Intelligence, Siri, language, fonts), Cryptexes, `/private/var/db/oah` (Rosetta), `/Library/Updates`, the sealed System volume, and CacheDelete's purge policy. Apple removed the Apple Intelligence off toggle in macOS 27 [S20].
5. **There is no public API for the per-category numbers in Storage settings.** Only volume-level numbers are public (URLResourceKey capacities, `statfs`, `getattrlist`, `diskutil`, `system_profiler`). Reconcile by computing the residual yourself (section 5).
6. **macOS 27 changed access and reporting in ways that hit a cleaner directly**:
   - Other teams' app containers, group containers, and a list of browser/Discord/wallet `Application Support` folders are now denied by default, with no prompt. [S7][S23]
   - Apple announced on 2026-10-02 that Full Disk Access will get "additional controls", with no date. [S8]
   - One community write-up claims macOS 27 stopped showing "purgeable" and folded it into System Data. That is single-source and user-authored, so verify it on a real machine (section 1.3). [S12]

## 1. What Apple counts as "System Data" and the other Storage categories

### 1.1 Apple's own definitions (first-party)

Source: Apple Support, "Change Storage settings on Mac" [S1]; "Free up storage space on Mac" (published 2026-10-16) [S2].

| Storage category | Apple's definition (paraphrased) | Typical location / mapping | Manageable in the pane? |
|---|---|---|---|
| Applications | Installed apps, excluding system applications | `/Applications`, `~/Applications` | Yes |
| Documents | Files in the home folder not in another category (PDFs, Pages, AirDropped photos). Includes Large Files, Downloads, File Browser. | `~/Documents`, `~/Desktop`, `~/Downloads`, other home files | Yes |
| iCloud Drive | Files stored in iCloud Drive, possibly Desktop/Documents too | `~/Library/Mobile Documents/...` (path from background knowledge, not in S1) | Partly |
| iOS Files | iOS backups and firmware | `~/Library/Application Support/MobileSync/Backup` (backups, per Apple [S4]); IPSW path not verified | Yes |
| TV / Music / Books / Podcasts | Purchases and downloads from each app, re-downloadable | per-app libraries | Yes |
| Mail | Emails and attachments | `~/Library/Mail` and Mail's container | Yes |
| Messages | Conversation content and attachments | `~/Library/Messages` | Yes |
| Music Creation | GarageBand, Logic, MainStage content | app support folders | Yes |
| Photos | System Photo Library | `Photos Library.photoslibrary` | Yes |
| Bin/Trash | Deleted items (iCloud Drive deletions excluded) | `~/.Trash` | Yes |
| Other Users | Files created, modified, or shared by other accounts | `/Users/<other>` | No |
| macOS | macOS system apps and files (e.g. Mail, Terminal, Calculator) | sealed System volume plus OS parts | No |
| **System Data** | Files that fit no other category: logs, caches, VM files, temp files, fonts, app support files, plug-ins, other runtime resources. Apple says you cannot manage it. | see section 2 | **No** |

Notes:
- Apple's doc does not list a "Developer" category. A dev write-up reports a "Developer" bar that was the largest item on that Mac [S42]. This is community-reported, single source. Treat it as "may appear when dev tools are installed".
- Apple says the pane's numbers refresh as you free space [S2], and that Safe Mode clears some system caches, which are re-created later [S2].
- The Applications and Documents categories are file-type buckets. A 40 GB Docker image in `~/Library/Containers` can land in Applications, Documents, or System Data depending on how Spotlight classifies it. I found no first-party doc on classification rules.

### 1.2 How System Data is computed (what is and isn't known)

- Apple Community's user-authored doc says category sizes are calculated "based on Spotlight". The doc also says the free-space bar changes after a few seconds, once calculation completes [S12]. This is single-source. It is consistent with Apple's own "everything that doesn't fit" wording [S1].
- Practical consequence: System Data is **not a folder**. It is `used - Σ(attributed categories)`. Any total you compute from the file system will differ by clone/sparse sharing, snapshots, purgeable items, and APFS-wide overhead.
- APFS clones make `du` unreliable. Local copies don't duplicate blocks [S36 thread 256130853, snippet]. A negative "used" has been reported in Storage settings.
- Overhead outside the Data volume: Preboot + Recovery are about 15 GB on a 2 TB internal drive [S12]. Cryptexes: `OS` 6.3 GB, `Incoming` 6.3 GB, `App` 40 MB on a Tahoe test Mac; Preboot reported 9.0 GB in `diskutil apfs list` [S21].
- The System volume itself is a bit over 15 GB, and around 28 GB on macOS 27 per Oakley's estimate as relayed by S21 (second-hand). Oakley 2022 measured about 15 GB [S43 (eclecticlight 2022-05-18), snippet].

### 1.3 What changed on macOS 26 and 27 (conflicting evidence, read carefully)

| Claim | Source and strength | Status |
|---|---|---|
| macOS 27 reconciled free vs. available space: purgeable no longer reported separately, no longer counted as available, and now included in System Data. Claimed jump: Tahoe System Data 9-40 GB vs Golden Gate 120-160 GB on one 2 TB Mac. | S12, Apple Community doc, user-authored (not Apple). Echoed by one forum reply in S44 (thread 256363764, snippet only). | **Single source, unverified.** Not in Apple's macOS 27 release notes (searched for storage/purgeable/System Data terms; nothing found) [S7]. |
| After the 27.0 upgrade, used space rose about 150 GB above baseline for the first 24 h, then settled about 30 GB above pre-upgrade level. Storage attributed 29.45 GB to AI on that Mac. | Oakley's measurements on a Mac mini M4 Pro, relayed by third-party site S21. I did not retrieve Oakley's primary posts. | **Second-hand, moderate.** |
| Measured Apple Intelligence storage: 20.67 GB (M4 Pro mini, MacRumors), 22.42 GB (M3 Air, Ars via S21), about 14 GB (M1 Air), 24.35 GB and 30.16 GB (Reddit users via MacRumors). Apple says up to 14 GB for M3+ with 12 GB RAM, up to 8 GB otherwise. | S21, S38 (MacRumors forum quoting Apple's figures) | **Moderate**, multiple Macs, mostly relayed. |
| The Apple Intelligence size is visible under System Settings > General > Storage > (i) next to **macOS**. | S20 (MacRumors, 2026-10-06) | Suggests AI assets are attributed to the **macOS** row, not System Data. Reports conflict on where they land. |
| macOS 27 removed the toggle that disabled Apple Intelligence entirely. Turning Siri AI off freed about 12.4 GB in one report, leaving about 25 GB. | S20 (MacRumors); S21 (relaying a reader of Oakley) | Moderate. |
| TidBITS forum user: Tahoe to Golden Gate raised System Data by about 30 GB and cut free space about 30 GB. | S45 (talk.tidbits.com, snippet) | Weak-moderate, one user. |
| Spotlight rebuilds after the major upgrade, inflating transient usage. | S21; Apple Community reply (S44) says Spotlight is rebuilding; another reply in the same thread says Spotlight indexing will not change System Data. | **Conflicting.** |
| On Tahoe, snapshots count as used, not purgeable, in some accountings; Disk Utility help treats purgeable as space macOS frees itself, but `tmutil` says local snapshots are purgeable and removable by `deleted`. Time Machine's CacheDelete service can fail to report purgeable space, and it can take about 30 minutes to notice new purgeable space. | S13 (Oakley 2026-08-28 on Tahoe 26.6.2, via mjtsai; excerpts only). Older: S14, S46. | Moderate-strong that accounting is inconsistent. |

Design implication: do not hardcode "macOS 27 includes purgeable in System Data". Detect empirically (section 5.4) and expose the individual components (snapshots, AI assets, caches) so the user can see where space is regardless of how Apple labels it.

## 2. Master table of contributors

Legend for **Access**:
- `U` = readable and deletable as the logged-in user, no extra permission.
- `FDA` = needs Full Disk Access (or the macOS 27 per-app data grant).
- `R` = needs root (privileged helper).
- `SIP` = SIP/sealed/system-managed; third parties cannot delete.
- `X` = not readable or not meaningful to read.

Sizes are "typical" only where a source gave a number. Otherwise they are marked *unverified*.

Safe? levels:
- **Yes** = safe, regenerated.
- **Careful** = safe only under conditions.
- **No** = do not delete directly.

| # | Item | Path(s) | Typical size | Access | Safe? | Sanctioned method | Sources |
|---|---|---|---|---|---|---|---|
| 1 | APFS local Time Machine snapshots (`com.apple.TimeMachine.<date>.local`) | Data volume snapshots, not files. List: `tmutil listlocalsnapshots /` | 0 to hundreds of GB; hourly, kept 24 h, plus one for the last backup, plus one before each macOS update | List: U (ran unprivileged in S21). Delete/thin: **R** with `tmutil` (and FDA for the calling process on recent macOS per community reports). Direct API create/delete needs entitlement `com.apple.developer.vfs.snapshot`, granted narrowly to backup apps. | Yes (regenerated hourly). Not yet-backed-up data is lost only from the local restore window. | Apple: set Time Machine backup frequency to Manually for a few minutes, then restore it [S3]. CLI: `sudo tmutil thinlocalsnapshots / <bytes> 4`, `sudo tmutil deletelocalsnapshots <date>`. UI: Disk Utility > Show APFS Snapshots. | S3, S16, S25, S19, S41, S33 (threads 89635, 786595) |
| 2 | Purgeable space (caches and snapshots macOS may evict) | Not a path. Calculated by `deleted` (CacheDelete), plists in `/System/Library/CacheDelete` | Tens of GB typical | Read: U via URLResourceKey. Purge decisions: **SIP**/system. | n/a | Do not purge manually. Free real space; macOS purges on demand. Read via `volumeAvailableCapacityForImportantUsage - volumeAvailableCapacity`. | S5, S6, S14, S15, S13 |
| 3 | Swap files | `/private/var/vm/swapfile*`, stored on the hidden **VM volume** in the boot volume group (Apple silicon and recent Intel) | 0 to tens of GB under memory pressure (*unverified for 2026*; Oakley notes it is only used when memory pressure demands) | R to read; **SIP/system-managed** | **No** | Reduce memory pressure, restart. Swap cannot be moved off the VM volume on current macOS. | S17, S11, S16 |
| 4 | Sleepimage | `/private/var/vm/sleepimage` | Reports from 1 GB to RAM-sized on older Macs. *Apple silicon size unverified.* | R; system-managed | No | `pmset` hibernation modes (not tested; do not recommend). | S17 (path), old StackExchange snippets; low confidence |
| 5 | `/private/var/folders` per-user temp and cache (`DARWIN_USER_TEMP_DIR` = `T`, `DARWIN_USER_CACHE_DIR` = `C`, also `0`) | `getconf DARWIN_USER_CACHE_DIR` returns `/private/var/folders/xx/yyyy/C/` | One user: 11 GB / 732k items [S29]; outlier 135 GB (App Store partial Xcode downloads) [S28] | Own user dir: **U**. Other users' dirs: R. Not SIP. | Careful. Files not in use are safe; delete only with the owning apps closed, prefer after restart. The system auto-cleans `T` (unused 3-4 days); `C` is not cleaned. | `sudo periodic daily` clean_tmps config (S28), or per-app clear. Prefer a conservative "older than N days, not open" rule. | S28, S29, S17 |
| 6 | `~/Library/Caches` | `~/Library/Caches/<bundle-id>/` | 14 GB on a 1 TB test Mac [S21]; "several GB" [S17] | U (most). Some app-owned subfolders in other developers' containers follow the macOS 27 container rule. | Yes, per app, with the app quit. Apps rebuild. | Per-app cache controls; Safe Mode clears system caches [S2]. | S2, S17, S19, S21 |
| 7 | `/Library/Caches` | `/Library/Caches/*` | *unverified* (MB to a few GB) | R for other owners' entries | Careful | None. Leave to apps and the OS. | background knowledge (no source found this cycle) |
| 8 | Spotlight index | `/System/Volumes/Data/.Spotlight-V100` (also per-volume) | Healthy: a few GB. Bug reports: 132 GB on a 460 GB SSD (semantic vector index, Tahoe) [S30, snippet only]. Reddit: System Data 260 GB to 83 GB after rebuild [S31]. | R | Yes (rebuilds, with CPU/disk cost and transient space growth) | `sudo mdutil -E /System/Volumes/Data` (erase and rebuild), check size with `sudo du -sh /System/Volumes/Data/.Spotlight-V100`. Don't `rm -rf` it. | S30, S31 |
| 9 | Unified logs | `/private/var/db/diagnostics/{Persist,Special,Signpost}`, `/private/var/db/uuidtext` | Persist: about 52 files, just over 500 MB (Oakley, 2020 Catalina; *may have grown*) | R | Persist logs: low value but removing hurts diagnostics. **Don't delete `uuidtext`** (needed to decode entries). | `log erase` (root; not tested here). `logd` self-prunes by folder size; no user setting. | S18, S47 (eclecticlight 2017 logd) |
| 10 | Apple Intelligence / Siri / language / font assets (MobileAsset, AssetsV2) | `/System/Library/AssetsV2/*` (firmlinked to the Data volume), e.g. `com_apple_MobileAsset_UAF_*`, `LinguisticData`, `Font8`, `SpotlightResources`, `iOSSimulatorRuntime` | Tahoe test Mac: AssetsV2 total 25 GB, of which 16.3 GB a simulator runtime, 3.0 GB LinguisticData, 2.5 GB Siri understanding [S21]. macOS 27 AI: 14-30 GB [S20, S21, S38]. Generic cleaners' "AI junk" claims unverified. | **SIP/system-managed**; readable by user (du works) | **No** | Settings: turn off Siri AI (about 12.4 GB reported); trim dictation and Translate languages; remove simulator runtimes via Xcode/`simctl`. macOS treats much of it as purgeable. No official full removal in macOS 27. | S20, S21, S38, S48 |
| 11 | `/private/var/MobileAsset` | legacy MobileAsset location | *Not verified.* Current assets reported under AssetsV2 [S21] | SIP/system | No | none | gap (see section 6) |
| 12 | Software Update leftovers | `/Library/Updates`, `/System/Library/...` update staging, `/System/Volumes/Data/macOS Install Data` | Seen as 2.5 GB to tens of GB *(unverified)* | **SIP** (Apple Community: deleting requires disabling SIP and enabling root, "not recommended") | **No** | Let macOS clean up after a successful install. Safe Mode / restart. Ensure Software Update's "Install system data files and security updates" is on (Apple). | S32 (threads 255962718, 251643920, snippets), S49 (Apple background-updates doc) |
| 13 | "Install macOS ..." installer apps | `/Applications/Install macOS *.app` | about 12-18 GB each *(background knowledge, unverified here)* | Admin auth to delete (root-owned); not SIP | Yes (re-downloadable) | Finder delete; `softwareupdate --list-full-installers` to re-fetch | gap; Macworld mentions leftover installers and `.dmg` [S19] |
| 14 | iOS/iPadOS device backups | `~/Library/Application Support/MobileSync/Backup/` | Often tens of GB per device | **FDA** (protected data; reported) | Careful: only copy of a device's data may live here | Finder > device > General > Manage Backups > Delete/Archive [S4]. Storage settings has an iOS Files/backups category [S1]. | S1, S4, S19 |
| 15 | IPSW firmware files | `~/Library/iTunes/iPhone Software Updates` (*path not verified*) | 5-8 GB each *(unverified)* | U | Yes | Delete files; Apple counts them under "iOS Files" [S1] | S1 only for category |
| 16 | Xcode DerivedData / Archives / Devices | `~/Library/Developer/Xcode/DerivedData`, `.../Archives`, `~/Library/Developer/CoreSimulator/Devices` | DerivedData 6.2 GB; Archives 3.9 GB; Devices 20 GB across 53 simulators (one 9.6 GB) [S24] | U | DerivedData: Yes. Archives: **No** (contain dSYMs of shipped builds). Devices: erase/delete per device. | `xcrun simctl erase <UDID>`, `xcrun simctl delete <UDID>`, `xcrun simctl delete unavailable` | S24, S19 |
| 17 | Simulator runtimes + Cryptex images | `/Library/Developer/CoreSimulator/Volumes/*` (mount points), images in system-managed storage; also `AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime` | about 8 GB per runtime; 31 GB for 4 runtimes; `du` on Volumes over-reports (51 GB) because it counts mounted contents [S24]. One Tahoe Mac: runtimes 15.7 GB. | `simctl` runs as **U** (a forum reply says to drop `sudo`); some runtimes are **SIP**-protected/orphaned | Yes for unused runtimes | `xcrun simctl runtime list`, `xcrun simctl runtime delete --notUsedSinceDays N --dry-run`, `--unusable`, `--outdated`, or Xcode > Settings > Components. **Known bugs:** runtimes can reappear after restart (forum 842603); orphaned 9 GB runtime in AssetsV2 can't be removed (812992); stale registry on macOS 27 beta (836929); `sudo simctl delete unavailable` didn't delete (837906). Forum items are snippets only. | S24, S21, S33 |
| 18 | Docker Desktop disk image | `~/Library/Containers/com.docker.docker/Data/vms/...` (exact path not verified); single large sparse `Docker.raw` | 30-80 GB commonly reported [S35 dev.to]; Docker docs confirm a single large disk image [S35] | U on macOS 26. On macOS 27: **another team's container**, so read/delete is denied by default without FDA [S7][S22]. | Careful: deletes all images/volumes | Inside Docker: `docker system df`, `docker system prune` (and volumes). The image file does not shrink on delete; use Docker Desktop's reclaim/resize. | S35, S7 |
| 19 | Other VM images (Parallels, UTM, VMware, Tart, Virtualization.framework) | typically `~/Parallels`, `~/Library/Containers/com.utmapp.UTM/...`, `~/.tart` *(paths not verified)* | Tens to hundreds of GB | U / FDA (containers) | **No** (user data) | The VM app's own tools | gap |
| 20 | Mail | `~/Library/Mail`, `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads`, Caches, `~/Library/Group Containers/UBF8T346G9.mail/...` | Can be 100+ GB (a user at 128 GB) [S50] | **FDA** | Mail Downloads and Caches: Yes. Mail store: **No**. | Mail: Mailbox > Erase Junk Mail / Erase Deleted Items; Message > Remove Attachments; Storage settings > Mail [S2]. Preference "Remove unedited downloads: when Mail quits". | S2, S50, S40 |
| 21 | Messages attachments | `~/Library/Messages/Attachments`, `.../Caches` | Large for heavy media users | **FDA** | Careful: deleting local attachments is harmless only if Messages in iCloud is on; otherwise data loss | Storage > Messages > More Info (Apple). | S1, S37 |
| 22 | iCloud Drive local copies / Optimize Mac Storage | `~/Library/Mobile Documents/com~apple~CloudDocs`, `~/Library/CloudStorage/*` | Varies | Reading is U; eviction needs the file-provider/iCloud API | Careful: evict (dataless), never delete | Settings: Store in iCloud / Optimize; Finder "Remove Download". Eviction depends on the Optimize Mac Storage setting [S14]. | S1, S14 |
| 23 | Photos library derivatives | `~/Pictures/Photos Library.photoslibrary/resources/derivatives`, `resources`, `originals`, `private` | Example: originals 41 GB, resources 42 GB [S36]; working copies about 20-30% of originals (reported) | U for the package; **FDA/Photos TCC** for Photos APIs | **No** (library internals) | Photos > Settings > iCloud > Optimize Mac Storage (reduces `originals` only, per community). | S36 |
| 24 | Sandbox containers | `~/Library/Containers/<bundle-id>/Data` (956 on a test Mac), `~/Library/Group Containers/*` (187) | Aggregate often tens of GB | macOS 15 added group-container protection; **macOS 27: other teams' containers denied by default**, no prompt; FDA or Files & Folders needed. XProtect may still restrict some data. | **No** (app data), except its `Library/Caches` subfolder | App's own controls. | S7 (161835690, 184660124), S22, S33 (766275, 756701) |
| 25 | Browser/app caches | Chrome `~/Library/Caches/Google/Chrome`, Slack, Spotify, Teams, Discord (*paths mostly background knowledge*) | GBs each *(unverified)* | Mostly U for `~/Library/Caches`. **macOS 27 protects `~/Library/Application Support` for Discord, Chrome, Brave, Edge, Firefox, Ledger Live, Exodus, Wasabi** (hardcoded list in `sandboxd`, updated via XProtect). Discord's cache sits under `Application Support/discord`, so it is likely blocked. | Yes (caches) | In-app "clear cache" first; direct deletion only if readable. | S23, S19 |
| 26 | Rosetta 2 AOT cache | `/private/var/db/oah/<UUID>/<hash>/*.aot` | Normally small; outliers 600-800 GB reported [S27] | **SIP**; owned by `_oahd`; users can't touch it even as root | **No** | None. A system update deletes the UUID directory; new one built on first x86-64 launch. Reduce Intel app use. | S26, S27 |
| 27 | Core dumps | `/cores` | Usually empty | R | Yes | Delete files as root | background knowledge |
| 28 | Diagnostic reports | `~/Library/Logs/DiagnosticReports`, `/Library/Logs/DiagnosticReports` | MBs | U / R | Yes | Console, or delete files | background knowledge |
| 29 | Homebrew caches | `~/Library/Caches/Homebrew` (`brew --cache`) | GBs for active users *(unverified)* | U | Yes | `brew cleanup` (and `--prune=all`) | background knowledge; Homebrew docs not retrieved |
| 30 | iPhone/iPad apps on Mac | `/Applications` wrappers; data in `~/Library/Containers/<id>` | Varies | Applications category | Careful | Uninstall the app | gap |
| 31 | Trash | `~/.Trash` | Varies | FDA to read from a non-Finder app (background knowledge) | Yes after user consent | Storage > "Empty Bin automatically" (30 days) [S1] | S1 |
| 32 | Deleted-but-open files | not on disk namespace | up to tens of GB | R to inspect (`sudo lsof +L1`) | n/a | Quit/restart the holding process | S31 |
| 33 | Cryptexes / Preboot / Recovery / VM overhead | `/System/Volumes/Preboot/Cryptexes/*`, `/System/Volumes/Preboot`, Recovery | about 9-15 GB | **SIP** | **No** | Managed by OS updates. Use `diskutil apfs list` for real sizes, not `du`. | S21, S12 |
| 34 | Quick Look thumbnails and subsystem caches | under `/private/var/folders/.../C/` etc. | MB-GB | U | Yes (purgeable per CacheDelete) | OS purges under pressure | S14 |

### 2.1 Per-item notes that don't fit the table

- **Snapshots are whole-volume.** They retain data that you delete or change after the snapshot. Size is not reported up front, and deleting an intermediate snapshot frees less than expected because older snapshots still hold the blocks. Delete oldest first [S16]. Disk Utility shows "Private Size" vs cumulative "Size" [S16].
- **Third-party snapshots are not purgeable by the OS.** Only Time Machine snapshots are purgeable via CacheDelete; CCC and similar apps' snapshots are not [S14]. Apple has not documented whether it can purge them [S13].
- **Time Machine stops making local snapshots on disks without plenty of free space** [S3]. The snapshot count Apple promises: hourly, 24 h, plus last backup, plus pre-update [S3].
- **Purgeable composition** per Oakley's log analysis of a purge (Ventura): volume caches, subsystem caches (Quick Look, Asset Cache, Mail caches), service/app-extension caches, plug-ins, Time Machine snapshots. Snapshots are purged last [S14]. This is Ventura-era analysis; treat as directional for 26/27.
- **iCloud eviction** depends on "Optimize Mac Storage" being on [S14].

## 3. Who can touch what (non-sandboxed, Developer-ID-signed app)

| Tier | What | Notes |
|---|---|---|
| **A. User-level, no special grant** | `~/Library/Caches` (most), DerivedData, CoreSimulator/Devices, Homebrew cache, your own `DARWIN_USER_*` dirs, `xcrun simctl runtime delete/list`, `docker` CLI | Fully doable as the user. Respect "in use" files and bundle-based exclusions. `simctl` ran without `sudo` in S24 and forum advice says to drop `sudo`. |
| **B. Needs Full Disk Access (TCC)** | Mail, Messages, Safari data, MobileSync backups, Photos library internals, `~/.Trash` (non-Finder), other apps' containers/group containers (macOS 27: denied by default), Application Support of protected apps (Chrome, Brave, Edge, Firefox, Discord, wallets) | TCC applies to root too: `sudo` does not help [S22]. FDA is bound to the app's code requirement, so a re-signed build drops the grant [S34]. Apple says FDA exists for backup apps and will get "additional controls", with no date or API [S8]. In macOS 27, apps can't read the TCC database directly [S7 (90775556)], and user-level TCC data moved under `/private/var/containers/Data/ProtectedSystem/...` [S23][S34]. |
| **C. Needs a root privileged helper** (`SMAppService.daemon(plistName:)`, user approves in Login Items; Apple: "registers so it can begin launching subject to user approval" [S9]) | `tmutil thinlocalsnapshots` / `deletelocalsnapshots`; `mdutil -E`; `log erase`; `/cores`; `/Library/Caches` entries owned by others; other users' `/private/var/folders` | Keep the helper tiny: a fixed allow-list of commands, no arbitrary paths, XPC code-signing check on callers. The helper executable itself needs the FDA grant for TCC-gated paths; the macOS 27 known issue says a process without a bundle ID can't get per-app container access and must use FDA instead [S7 (184660124)]. Whether `tmutil` run by a root daemon needs FDA is likely but not verified. Test on a real macOS 27 machine. |
| **D. Nothing third-party can touch** | Sealed System volume and `/System/*`; `/System/Library/AssetsV2` (AI/Siri/language/fonts, SIP-managed, so orphans can't be deleted: forum 812992 is title-only evidence); Cryptexes under Preboot; `/private/var/db/oah` (SIP + `_oahd`); `/Library/Updates`; VM volume swap; `/System/Library/CacheDelete` plists; CacheDelete's purge decisions | SIP applies to every process, sandboxed or root [S10]. Don't tell users to disable SIP. Offer only the Settings toggles and the CLIs Apple gave (Siri AI off, languages, `simctl`). |

Third-party AI-model strippers exist (RemoveMacAI, via MacRumors) but go outside Apple-supported behavior and disable AI features; don't ship equivalent logic [S20].

## 4. Apple-sanctioned reduction methods (summary)

| Target | Method |
|---|---|
| Local snapshots | Time Machine backup frequency to Manually for a few minutes [S3]; `tmutil thinlocalsnapshots / <bytes> <urgency 1-4>` or `deletelocalsnapshots <date|mount>` [S25]; Disk Utility > Show APFS Snapshots |
| iOS backups | Finder > device > Manage Backups [S4] |
| Mail | Erase Junk / Erase Deleted Items; Remove Attachments [S2] |
| Messages / Documents / Trash | Storage > More Info panes; Empty Bin automatically [S1] |
| iCloud | Store in iCloud; Optimize Mac Storage [S1][S2] |
| System caches | Safe Mode (clears some system caches, regenerated) [S2] |
| Simulators | `xcrun simctl runtime delete`, `xcrun simctl delete unavailable`, Xcode Settings > Components [S24] |
| Spotlight | `mdutil -E` rebuild [S31] |
| AI assets | Siri AI off (about 12.4 GB reported); trim languages. No master off switch on macOS 27 [S20][S21] |
| Software updates | Leave to macOS; "Install system data files and security updates" setting [S49] |

## 5. Getting the same numbers as Storage settings

### 5.1 What exists

| Need | API / tool | What it gives | Notes |
|---|---|---|---|
| Volume total | `URLResourceKey.volumeTotalCapacityKey`, `statfs`, `diskutil info` | Total bytes | Public |
| "Free" (excluding purgeable) | `volumeAvailableCapacityKey`, `statfs.f_bavail`, `df`, Disk Utility, System Information | Space free now | Matches Disk Utility on pre-27 macOS [S12] |
| "Available" including purgeable | `volumeAvailableCapacityForImportantUsageKey` (macOS 10.13+) | Free + purgeable macOS thinks it can reclaim for **important** (user-requested) data | Apple's guidance: use Important for user-requested content, Opportunistic for predictive downloads [S6]. Values derive from CacheDelete's latest figures [S15]. |
| Opportunistic | `volumeAvailableCapacityForOpportunisticUsageKey` | Smaller figure for non-essential data | [S5][S6] |
| Purgeable | Derived: Important - Available | No dedicated key (forum 127736, snippet [S33]) | |
| Volume used | `getattrlist` `ATTR_VOL_SPACEUSED`, `statfs` (f_blocks - f_bfree) | Used bytes | Forum 783462/783594: calculated in the VFS layer; returns EINVAL on some older OSes [S33, snippets] |
| Container/volume breakdown | `diskutil apfs list -plist`, `diskutil info -plist /` (Container Free Space, volume consumption) | Per-volume "capacity consumed" | CLI only; parse plist |
| Same via system_profiler | `system_profiler SPStorageDataType -json` | `free_space_in_bytes`, `size_in_bytes`, `mount_point` (e.g. `/System/Volumes/Data`) | Seen in S39 snippet; slow-ish |
| Snapshots | `tmutil listlocalsnapshots /`, `fs_snapshot_list` (no entitlement needed to list) | Names/dates; the returned size is metadata size, **not** reclaimable bytes | [S33 thread 89635 snippet] |
| Per-category (Applications/Documents/System Data...) | **No public API found.** Apple's pane appears to be Spotlight-based [S12, weak]. | n/a | I did not find a private-framework name with a primary source; avoid private APIs for a Developer-ID app you want notarized and stable. |

The Important-usage key has a privacy-manifest note in Apple's docs: declare required-reason API use in `PrivacyInfo.xcprivacy` [S5]. Apple's documented trigger is App Store-style submissions; I did not verify enforcement for Developer-ID apps.

### 5.2 Swift sketch

```swift
let url = URL(fileURLWithPath: "/")
let v = try url.resourceValues(forKeys: [
  .volumeTotalCapacityKey,
  .volumeAvailableCapacityKey,
  .volumeAvailableCapacityForImportantUsageKey,
  .volumeAvailableCapacityForOpportunisticUsageKey
])
let total = Int64(v.volumeTotalCapacity ?? 0)
let free = Int64(v.volumeAvailableCapacity ?? 0)
let important = v.volumeAvailableCapacityForImportantUsage ?? 0
let purgeableEstimate = max(0, important - free)
```

Use a URL on the **Data volume** (`/System/Volumes/Data` or `~`) when reconciling with Storage settings. Any file URL on the volume works [S33 thread 113250, snippet].

### 5.3 Reconciliation recipe

1. Container: `diskutil info -plist /` for container size and free space (shared across all volumes in the container).
2. Per-volume: `diskutil apfs list -plist` → Data, System, Preboot, Recovery, VM, update volumes.
3. Your own measurement of each category (sizes from walking the folders you can read; use allocated size, clone-aware where possible).
4. Snapshots: count and approximate size from `tmutil listlocalsnapshots /` plus Disk Utility's Private Size (not exposed via API).
5. Purgeable estimate from step 5.2.
6. Residual: `used - Σ(categories) = "unattributed, Apple-managed"`. Show it as its own bucket and name its known members (AI assets, Spotlight, logs, swap, Rosetta, snapshots, caches).
7. Display two totals side by side: "Free (guaranteed)" and "Available (incl. purgeable)". Wait for the numbers to settle before comparing with Apple's pane, because Storage recalculates for several seconds after opening [S12] and Finder keeps stale values [S15].

### 5.4 macOS 27 detection

Because the macOS 27 reclassification claim [S12] is unverified:
- On first run on 27, compute `important - free`. If it is about 0 on a Mac that had large purgeable on Tahoe, the claim is plausible. Log it to a diagnostics file the user can share.
- Don't gate features on `ProcessInfo.operatingSystemVersion`; gate on observed behavior.
- Expect Apple's pane and your numbers to differ by a few GB in any case (rounding, decimal GB: Apple uses powers of 10).

## 6. Gaps and verification still needed

- **Primary Oakley posts for 2026** (macOS 27 upgrade tracking; AI storage) were not retrieved. I rely on Michael Tsai's excerpts [S13] and a third-party relay [S21]. Fetch eclecticlight.co posts from Aug-Oct 2026 before quoting numbers.
- **Apple Community and Apple Developer Forums** pages mostly blocked my fetcher (verification interstitial). Facts from them are snippet-level: S30, S32, S33, S44, S45.
- **Apple Community DOC-250012471** (purgeable folded into System Data) is user-authored, not Apple. Verify on real hardware.
- **Unsourced rows**: /Library/Caches, sleepimage on Apple silicon, `/private/var/MobileAsset`, IPSW path, `/cores`, DiagnosticReports, Homebrew, `.Trash` TCC, Docker.raw path, third-party VM paths, Slack/Teams/Spotify paths, installer sizes. They need a quick test on a clean macOS 26/27 VM.
- **Does a root daemon need FDA to run `tmutil`?** Not verified.
- **Where AI assets are attributed** (macOS row vs System Data). Conflicting reports; one tester is enough to settle it by comparing `AssetsV2` size with Storage's rows.
- Sites like macos-tahoe.com, gadgethacks, dev.to, Medium and cleaner-vendor blogs are secondary and sometimes promotional. They are labeled as such and are not used alone for any "strong" claim.

## 7. Recommendations for TruongCleaner

1. **Don't promise to "clean System Data".** Show a decomposition (table section 2) with a named "Apple-managed, not removable" bucket (AI assets, Cryptexes, Rosetta, swap, CacheDelete).
2. **Ship a snapshot manager first.** It's the biggest, most reversible win and the only major item needing a root helper. Use `tmutil thin/delete`, show count and the "Private Size" caveat, and say hourly snapshots return.
3. **Ship a developer cleaner second.** `simctl` (runtime, delete unavailable), DerivedData, Docker (guide to `docker system prune`; never touch `Docker.raw` directly).
4. **Make Full Disk Access optional and degrade gracefully.** Apple has signaled a stricter FDA flow [S8]; macOS 27 already denies other teams' containers [S7]. Provide "denied" states, re-check after each signing change [S34], and never read the TCC DB [S7].
5. **Use the Spotlight rebuild as a guided action** with a warning that it spikes CPU and disk and may temporarily grow System Data.
6. **Reconcile with the recipe in section 5.3** and show two "free" numbers.
7. **Test matrix:** macOS 15, 26, 27 on 256 GB and 1 TB, with and without Xcode and Docker.

## Sources

Primary (Apple):
- S1 Apple Support, Change Storage settings on Mac: https://support.apple.com/en-sg/guide/mac-help/mchl3d437fbc/mac
- S2 Apple Support, Free up storage space on Mac (published 2026-10-16): https://support.apple.com/en-lamr/102624
- S3 Apple Support, About Time Machine local snapshots (published 2026-07-06): https://support.apple.com/en-kg/102154
- S4 Apple Support, Locate and manage backups of your iPhone, iPad, and iPod touch: https://support.apple.com/en-us/108809
- S5 Apple Developer, volumeAvailableCapacityForImportantUsageKey: https://developer.apple.com/documentation/foundation/urlresourcekey/volumeavailablecapacityforimportantusagekey
- S6 Apple Developer, Checking Volume Storage Capacity: https://developer.apple.com/documentation/foundation/checking-volume-storage-capacity
- S7 Apple Developer, macOS 27 Release Notes (items 161835690, 184660124, 90775556): https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes
- S8 Apple Developer News, Updates to Full Disk Access in macOS (2026-10-02): https://developer.apple.com/news/?id=p6zjojqw
- S9 Apple Developer, SMAppService: https://developer.apple.com/documentation/servicemanagement/smappservice
- S10 Apple Platform Security, System Integrity Protection: https://support.apple.com/guide/security/system-integrity-protection-secb7ea06b49/web
- S11 Apple Platform Security, Role of APFS (VM volume; snippet): https://support.apple.com/en-eg/guide/security/seca6147599e/web
- S49 Apple Support, About background updates in macOS: https://support.apple.com/en-us/101591 (snippet)

Howard Oakley (The Eclectic Light Company):
- S13 via Michael Tsai, "Aren't Snapshots Purgeable?" (2026-08-28, with 09-03/09-08 updates): https://mjtsai.com/blog/2026/08/28/arent-snapshots-purgeable/
- S14 Ventura space management: what gets purged and how (2023-04-19): https://eclecticlight.co/2023/04/19/ventura-space-management-what-gets-purged-and-how/
- S15 Where does macOS get its volume free space figures from? (2023-04-27): https://eclecticlight.co/2023/04/27/where-does-macos-get-its-volume-free-space-figures-from/
- S16 Managing snapshots (2022-02-10): https://eclecticlight.co/2022/02/10/managing-snapshots-how-to-stop-them-eating-free-space/
- S17 Caches, buffers and swap (2023-02-04): https://eclecticlight.co/2023/02/04/caches-buffers-and-swap/
- S18 How long does your Mac keep its log for? (2020-02-07): https://eclecticlight.co/2020/02/07/how-long-does-your-mac-keep-its-log-for/
- S43 How much free space does an APFS disk need? (2022-05-18, snippet): https://eclecticlight.co/2022/05/18/how-much-free-space-does-an-apfs-disk-need/
- S46 What is purgeable disk space? (2023-04-15, snippet): https://eclecticlight.co/2023/04/15/what-is-purgeable-disk-space/
- S47 logd and the files that it manages (2017, snippet): https://eclecticlight.co/2017/10/10/inside-the-macos-log-logd-and-the-files-that-it-manages/

Press / community / third-party (secondary):
- S12 Apple Community doc (user-authored), System Data and Free Space Changes in Golden Gate: https://discussions.apple.com/docs/DOC-250012471
- S19 Macworld, How to clear System Data on Mac: https://www.macworld.com/article/676493/how-to-delete-system-data-mac.html
- S20 MacRumors, This Tool Strips AI Models From macOS (2026-10-06): https://www.macrumors.com/2026/10/06/strip-apple-intelligence-from-macos-27/
- S21 macos-tahoe.com (third party; relays Oakley, MacRumors, Ars), macOS 27 Took 30 GB: https://macos-tahoe.com/blog/macos-27-disk-space-30gb-apple-intelligence-storage-after-upgrade-2026/
- S22 macos-tahoe.com, macOS 27 Blocks Access to Other Apps' Data (quotes Apple release notes): https://macos-tahoe.com/blog/macos-27-app-data-containers-access-denied-operation-not-permitted-fix-2026/
- S23 Wojciech Regula, macOS's New Application Support Protection: https://wojciechregula.blog/post/golden-gate-appdata-protection/
- S24 dev.to (StorageRadar author), Where 51 GB of Xcode simulator storage went: https://dev.to/chamav/where-51-gb-of-xcode-simulator-storage-went-on-my-mac-4a99
- S25 tmutil(8) mirror (dssw): https://dssw.co.uk/reference/tmutil/
- S26 Mandiant/Google Cloud, Rosetta 2 artifacts: https://cloud.google.com/blog/topics/threat-intelligence/rosetta2-artifacts-macos-intrusions
- S27 Apple Community, Rosetta cache size threads (snippets): https://discussions.apple.com/thread/254170900 and https://apple.stackexchange.com/questions/427695/how-can-i-limit-the-disk-usage-of-the-rosetta-2-oah-cache
- S28 ctrl.blog, The missing gigabytes of disk space on my Mac: https://www.ctrl.blog/entry/darwin-user-cache-gigabytes/
- S29 TidBITS Talk, Self cleaning of /private/var/folders (snippet): https://talk.tidbits.com/t/self-cleaning-of-private-var-folders/29980
- S30 Apple Community, .Spotlight-V100 grows to 130+ GB (snippet only; page blocked): https://discussions.apple.com/thread/256284468
- S31 jonathansblog.co.uk (adapted from r/MacOS), Spotlight index: https://jonathansblog.co.uk/freeing-up-180gb-on-macos-by-rebuilding-the-spotlight-index
- S32 Apple Community, /Library/Updates threads (snippets): https://discussions.apple.com/thread/255962718 , https://discussions.apple.com/thread/251643920
- S33 Apple Developer Forums (snippets, pages blocked): threads 89635, 786595, 127736, 783462, 783594, 113250, 766275, 756701, 812992, 842603, 836929, 817922, 837906 (all under https://developer.apple.com/forums/thread/<id>)
- S34 dev.to (devinios), Apple just linked "AI agents" to Full Disk Access restrictions: https://dev.to/devinios/apple-just-linked-ai-agents-to-full-disk-access-restrictions-here-is-what-that-means-for-tooling-95h
- S35 Docker Desktop for Mac FAQ: https://docs.docker.com/desktop/troubleshoot-and-support/faqs/macfaqs ; dev.to Docker.raw: https://dev.to/diskinsight/dockerraw-why-is-my-mac-out-of-space-when-docker-is-empty-3eb9
- S36 Apple Community Photos threads (snippets): https://discussions.apple.com/thread/251340752 , https://discussions.apple.com/thread/254881631 , https://discussions.apple.com/thread/256130853
- S37 Apple Community, Messages on iCloud (snippet): https://discussions.apple.com/thread/256000543
- S38 MacRumors forum thread on Apple Intelligence taking 30GB+ (quotes Apple's 14 GB / 8 GB): https://forums.macrumors.com/threads/apple-intelligence-taking-up-30gb-on-some-macs-running-macos-27.2490285/page-7
- S39 BigFix forum, SPStorageDataType JSON (snippet): https://forum.bigfix.com/t/macos-spsoftwaredatatype-fun-with-json/51411
- S40 macuncle, Mail cache (snippet): https://www.macuncle.com/blog/clear-apple-mail-cache-on-mac/
- S41 Apple Community, tmutil/snapshot deletion threads (snippets): https://discussions.apple.com/thread/255891579 , https://discussions.apple.com/thread/256193642
- S42 dev.to (nixeton), Your Dev Tools Are Why Your Mac is Full: https://dev.to/nixeton/your-dev-tools-are-why-your-mac-is-full-heres-how-to-reclaim-50-100gb-3n8b (snippet)
- S44 Apple Community, MacOS 27 System data using 50% of disk space (snippet; page blocked): https://discussions.apple.com/thread/256363764
- S45 TidBITS Talk, When Should You Upgrade to Apple's OS 27 Releases? (snippet): https://talk.tidbits.com/t/when-should-you-upgrade-to-apple-s-os-27-releases/34159/47
- S48 Apple Community, How to remove AI features to reclaim SSD (snippet): https://discussions.apple.com/thread/256356897
- S50 Apple Community, Mail storage not reducing (snippet): https://discussions.apple.com/thread/256312646
