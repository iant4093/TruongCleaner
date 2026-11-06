# TruongCleaner: tech stack research (E)

Research date: 2026-11-06. Test machine: macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift 6.4 (swiftlang-6.4.0.34.1), arm64.

Evidence tags used throughout:

- **[V]** Verified on this Mac this session (compiled, ran, measured, or read from the installed macOS 27.0 SDK).
- **[S]** Taken from a cited source. Source quality is noted when it is third-party.
- **[I]** My inference. No source states it directly.

Content from web sources is paraphrased.

---

## 0. Decisions at a glance

| Decision | Recommendation | Main reason |
|---|---|---|
| Minimum deployment target | **macOS 26.0**, built with the Xcode 27 SDK | Every Liquid Glass API is macOS 26. The macOS 27 SDK adds no new SwiftUI glass API [V]. macOS 26 is the larger install base. |
| Architectures | **arm64 only** | macOS 27 dropped Intel. The `xcode-27` runner image is arm64 only. Homebrew and CodeQL are also dropping Intel. |
| Sandbox | **Not sandboxed**, distributed outside the Mac App Store | Mac App Store rule 2.4.5 forbids root escalation, requires a sandbox, and forces MAS-only updates. Those rules conflict with a cleaner. |
| Signing path | **Phase 1: ad-hoc, no helper.** Phase 2: Developer ID + notarization when the owner pays | Ad-hoc works for a GitHub download plus "Open Anyway". The official Homebrew cask, a privileged helper, stable FDA grants, and a friction-free first launch all need Developer ID. |
| Privileged helper | **Do not build one in v1** | There is no evidence that `SMAppService.daemon` registers with an ad-hoc signature. See section 3.4. |
| Update mechanism | **Sparkle 2.10.x with EdDSA** and an appcast served from the latest GitHub Release. The zero-dependency alternative is a notify-only checker against the GitHub Releases API | Sparkle accepts ad-hoc-signed updates. It adds about 3 MB. |
| Test framework | **Swift Testing** in local SwiftPM packages. XCTest only for UI tests | `swift test` ran Swift Testing on macOS 27 with no simulator [V]. Xcode 27 defaults to XCTest/Swift Testing interoperability. |
| CI runner | `runs-on: xcode-27` (not `macos-27`, which does not exist) | See section 5. |
| CodeQL for Swift | **Unavailable on Xcode 27 / Swift 6.4.** Keep CodeQL on workflows only | GitHub changelog 2026-10-19. |

Biggest risks for a disk cleaner, found in this research:

1. macOS 27 **denies access to other developer teams' app containers by default and without a prompt**. Full Disk Access (FDA) is the documented workaround (section 3.1).
2. macOS 27 **moved the user TCC database** and bars apps from reading it. The classic `TCC.db` FDA probe is dead (section 3.2).
3. On 2026-10-02 Apple announced it will **add controls that make FDA harder to grant** (section 3.3). FDA-dependent design carries policy risk.
4. An **ad-hoc signature's identity is its code hash**, which changes every build [V]. This breaks stable permission grants and XPC peer pinning across updates (sections 3.4 and 4.1).

---

## 1. UI: SwiftUI and Liquid Glass on macOS 26 / 27

### 1.1 What I could verify

I compiled a sample window against the macOS 26.0 target with `-swift-version 6 -warnings-as-errors -O` on Xcode 27.0. It compiled with zero warnings **[V]**. The sample used:
`NavigationSplitView`, `List(selection:)`, `.searchable(placement: .sidebar)`, `Form` with `.formStyle(.grouped)`, `LabeledContent`, `Chart`/`BarMark`, `GlassEffectContainer`, `.glassEffect(.regular.tint(_:).interactive(), in:)`, `.glassEffect(.clear, in:)`, `.glassEffectID(_:in:)`, `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)`, `.buttonStyle(.glass(.clear))`, `.backgroundExtensionEffect()`, `.inspector(isPresented:)`, `ToolbarSpacer(.fixed)`, `@Observable @MainActor`, `\.appearsActive`, `\.accessibilityReduceTransparency`, and `NSWorkspace.activateFileViewerSelecting`.

The code is in the appendix.

I confirmed each availability from Apple's documentation JSON (`developer.apple.com/tutorials/data/documentation/...`) **[V]**. Rows marked "26.0" below have `introducedAt: 26.0` for macOS.

### 1.2 API table (names are exact)

| API | macOS | Doc link | Notes |
|---|---|---|---|
| `View.glassEffect(_:in:)` | 26.0 | [doc](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)) | Defaults: `.regular` glass in a capsule. |
| `Glass` (`.regular`, `.clear`, `.identity`) | 26.0 | [doc](https://developer.apple.com/documentation/swiftui/glass) | Modifiers: `.tint(_:)`, `.interactive(_:)`. |
| `GlassEffectContainer` | 26.0 | [doc](https://developer.apple.com/documentation/swiftui/glasseffectcontainer) | Groups nearby glass so shapes blend and morph. Use it whenever two or more glass elements sit close together. |
| `View.glassEffectID(_:in:)` | 26.0 | [doc](https://developer.apple.com/documentation/swiftui/view/glasseffectid(_:in:)) | Needs an `@Namespace`. |
| `View.glassEffectUnion(id:namespace:)` | 26.0 | [doc](https://developer.apple.com/documentation/swiftui/view/glasseffectunion(id:namespace:)) | |
| `View.glassEffectTransition(_:)` | 26.0 | [doc](https://developer.apple.com/documentation/swiftui/view/glasseffecttransition(_:)) | |
| `.buttonStyle(.glass)`, `.glassProminent` | 26.0 | [GlassButtonStyle](https://developer.apple.com/documentation/swiftui/glassbuttonstyle), [GlassProminentButtonStyle](https://developer.apple.com/documentation/swiftui/glassprominentbuttonstyle) | `.glass(_:)` takes a `Glass`, so `.glass(.clear)` compiles [V]. |
| `View.backgroundExtensionEffect()` | 26.0 | [doc](https://developer.apple.com/documentation/swiftui/view/backgroundextensioneffect()) | Mirrors and blurs adjacent content under a sidebar or inspector. |
| `ToolbarSpacer` | 26.0 | [doc](https://developer.apple.com/documentation/swiftui/toolbarspacer) | `.fixed` and `.flexible` kinds. |
| `ToolbarContent.sharedBackgroundVisibility(_:)` | 26.0 | [doc](https://developer.apple.com/documentation/swiftui/toolbarcontent/sharedbackgroundvisibility(_:)) | Removes the shared glass pill behind a toolbar item. |
| `View.scrollEdgeEffectStyle(_:for:)`, `scrollEdgeEffectHidden(_:for:)` | 26.0 | [doc](https://developer.apple.com/documentation/swiftui/view/scrolledgeeffectstyle(_:for:)) | |
| `View.searchToolbarBehavior(_:)` | 26.0 | [doc](https://developer.apple.com/documentation/swiftui/view/searchtoolbarbehavior(_:)) | |
| `ConcentricRectangle`, `containerShape(_:)` | 26.0 | [doc](https://developer.apple.com/documentation/swiftui/concentricrectangle) | For corners that match the window. |
| `ToolbarContent.visibilityPriority(_:)` | 26.1 | [doc](https://developer.apple.com/documentation/swiftui/toolbarcontent/visibilitypriority(_:)) | Overflow priority. |
| `ToolbarOverflowMenu` | **not on macOS** | [doc](https://developer.apple.com/documentation/swiftui/toolbaroverflowmenu) | The doc JSON lists no macOS availability [V]. A third-party API reference says iOS only. |
| `NavigationSplitView`, `.inspector(isPresented:)`, `.inspectorColumnWidth` | 13.0 / 14.0 | [NSV](https://developer.apple.com/documentation/swiftui/navigationsplitview), [inspector](https://developer.apple.com/documentation/swiftui/view/inspector(ispresented:content:)) | Standard components. They pick up glass automatically when built with the 26+ SDK. |
| `FormStyle.grouped` | 13.0 | [doc](https://developer.apple.com/documentation/swiftui/formstyle/grouped) | The System Settings look: inset rounded groups. |
| `searchable(text:placement:prompt:)` with `.sidebar` | 13.0 | [doc](https://developer.apple.com/documentation/swiftui/view/searchable(text:placement:prompt:)) | |
| `Chart`, `BarMark`, `SectorMark` | 13.0 / 13.0 / 14.0 | [Charts](https://developer.apple.com/documentation/charts) | System framework. No size cost. |
| `@Observable` | 14.0 | [doc](https://developer.apple.com/documentation/observation/observable()) | |
| `NSGlassEffectView`, `NSGlassEffectContainerView` | 26.0 | [NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview) | AppKit equivalents. Only needed if you drop to AppKit. |
| `EnvironmentValues.appearsActive` | 10.15 | [doc](https://developer.apple.com/documentation/swiftui/environmentvalues/appearsactive) | Use it to dim custom chrome in inactive windows. |
| `EnvironmentValues.accessibilityReduceTransparency` | 10.15 | [doc](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducetransparency) | Only for custom backgrounds. See 1.5. |

Design guidance to follow: [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass), [HIG: Materials](https://developer.apple.com/design/human-interface-guidelines/materials), [HIG: Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars), [HIG: Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), [HIG: Settings](https://developer.apple.com/design/human-interface-guidelines/settings), [WWDC25 323 "Build a SwiftUI app with the new design"](https://developer.apple.com/videos/play/wwdc2025/323).

Rules that matter for a System-Settings-style app **[S]**:

- Apple's guide says to remove custom backgrounds on split views, toolbars and tab bars so the system material can show, and to reduce tinted controls in toolbars ([Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass), [HIG: Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)).
- Apple's guide frames sidebars and inspectors as part of the navigation layer that floats over content, with `backgroundExtensionEffect` for content that should appear to continue under them.
- Use glass on controls and navigation only, not on content rows. A `Form` with `.grouped` style already looks like System Settings and needs no glass.
- Wrap adjacent custom glass in `GlassEffectContainer`.

### 1.3 System Settings-style rows with colored icon tiles

There is no public API for the tiles. System Settings draws them with private icon rendering (a Stack Overflow answer describes `ISGraphicIconConfiguration` and says the icons follow the normal/dark/clear/tinted icon styles; third-party, [link](https://stackoverflow.com/questions/79944533/how-to-make-dynamic-nsimage-icon-based-on-sf-symbol-name)). Do not use private API. Draw the tile yourself:

```swift
struct IconTile: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
```

This compiled [V]. The 24 pt size and 6 pt radius are my visual approximation. Compare against a screenshot of System Settings and adjust. A Stack Overflow answer for the iOS Settings app uses 28 pt with a 7 pt radius, which is the same ~0.25 ratio ([link](https://stackoverflow.com/questions/69836958/how-would-you-make-icons-like-in-the-settings-app-swiftui)).

For row layout use `Label { Text } icon: { IconTile }` inside `List`/`Form`. Use `LabeledContent` for "title ... value" rows.

### 1.4 What changed in macOS 27 / WWDC26

**System-level (apps get it with no code):**

- A single **Liquid Glass appearance slider** in System Settings > Appearance, from "ultra-clear" to "fully tinted". It defaults to medium and applies to the Dock, widgets, sidebars, toolbars and toolbar buttons ([9to5Mac, 2026-09-22](https://9to5mac.com/2026/09/22/macos-27-gives-you-more-control-over-liquid-glass/); Apple's macOS 27 story page: [apps.apple.com](https://apps.apple.com/us/mac/story/id1896606928)). SwiftUI glass responds automatically ([WWDC26 SwiftUI breakdown, third-party](https://dev.to/arshtechpro/wwdc26-whats-new-in-swiftui-a-developers-breakdown-1333)). One consequence: your glass can look clearer or more opaque than your screenshots. Test at both extremes.
- Uniform toolbars, edge-to-edge sidebars and updated window shapes (Apple story page above).
- Custom interactive glass on Mac reacts more smoothly to the pointer (SwiftUI breakdown above).

**New in the macOS 27.0 SDK (read from the installed SDK) [V]:**

- **SwiftUI: no new glass API.** I scanned `SwiftUI.swiftinterface` and `SwiftUICore.swiftinterface` in the macOS 27.0 SDK for declarations marked `@available(macOS 27` or `@available(anyAppleOS 27.0`. Every declaration whose name contains "glass" is still `macOS 26.0`. The new 27 declarations are: `GeometryProxy.concentricCornerRadii` and `concentricCornerRadii(in:)`, `TextInputBorderShape` with `textInputBorderShape(_:)` and `TextFieldStyle.bordered`, `toolbarMinimizationBehavior(_:for:)`, `ToolbarItemVisibilityPriority` becoming `Comparable`, `contentMarginsRemoved(_:)` for toolbar content, `presentationPlacement(_:)`, `asyncImageURLSession(_:)`, `alert(error:...)`, the document protocols (`ReadableDocument`, `WritableDocument`, `DocumentReader`, `DocumentWriter`, `DocumentCreationSource`), `reorderable()` / `reorderContainer`, `swipeActions` on any view with `swipeActionsContainer()`, `TabsPickerStyle` (`.tabs`), the `ContentBuilder` result builder, and `Preview` macro overloads. I did not test which of these have any effect on macOS (some, like `toolbarMinimizationBehavior`, are described by a third-party guide as iOS navigation-bar features).
- **AppKit:** `NSGlassEffectView.effectIsInteractive` (macOS 27.0, from the SDK header), plus the corner-concentricity types `NSViewCornerConfiguration`, `NSViewCornerRadii`, `NSViewCornerRadius`, and `NSToolbarItemGroup.role`. Apple's macOS 27 beta 3 release notes also list `concentricCornerRadii` (gist copy of Apple's page: [link](https://gist.github.com/applch/9b53eeb96c4cf097efa2cb5c9bd53b97)).
- Other WWDC26 SwiftUI changes (third-party breakdown, not independently verified here): `@State` became a macro and initializes `@Observable` objects lazily (back-deployed to macOS 14), `ContentBuilder` reduces type-checker blowups, the toolbar APIs `visibilityPriority` and `ToolbarOverflowMenu` are for small screens. Primary source: [WWDC26 session 269 "What's new in SwiftUI"](https://developer.apple.com/la/videos/play/wwdc2026/269/) (the English page did not render for me; this is the Spanish page).
- The `@State` source break: if you give an `@State` property a default value and then assign it in `init`, Xcode 27 reports "used before being initialized". Declare it without a default (same breakdown).

**"Clear" and "tinted" variants.** Two meanings exist, and they are easy to confuse:

1. **Per-view variants:** `Glass.regular` vs `Glass.clear`, and `.buttonStyle(.glass(.clear))`. HIG says to use `regular` where legibility matters or text is dense (sidebars, alerts, popovers), and to use `clear` only over media-rich backgrounds. It suggests a dimming layer of about 35% opacity behind clear glass when the content underneath is bright ([HIG: Materials](https://developer.apple.com/design/human-interface-guidelines/materials)). A disk cleaner has no media backgrounds, so use **`.regular` everywhere**.
2. **User-level appearance** (the slider, and app-icon default/dark/clear/tinted styles). You do not control it. You need a tinted/clear-aware icon via Icon Composer only (SF Symbols 8 and Icon Composer 2 are the matching tools: [9to5Mac](https://9to5mac.com/2026/06/12/icon-composer-2-and-sf-symbols-8-now-available-as-betas/)).

**SF Symbols.** SF Symbols 8 shipped as a beta at WWDC26 with over 7,000 symbols and new symbols for the 27 releases ([9to5Mac, 2026-06-12](https://9to5mac.com/2026/06/12/icon-composer-2-and-sf-symbols-8-now-available-as-betas/)). Symbols introduced in 27 are not available on macOS 26. If you target 26, either pick symbols that exist in SF Symbols 7 or gate with `#available`. The SF Symbols app flags each symbol's introduction version.

### 1.5 Reduce Transparency and accessibility

- Apple states that system settings such as a preferred Liquid Glass look, reduced transparency, increased contrast or reduced motion can remove or alter glass effects, and standard components adapt automatically ([Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass), [HIG: Materials](https://developer.apple.com/design/human-interface-guidelines/materials)).
- Your job is only the **custom** pieces: any hand-built background, custom colors, and any text you place over glass. Read `\.accessibilityReduceTransparency` and swap to an opaque `.background(.regularMaterial)` or a solid color when it is true. Check contrast with Increase Contrast on. Dim custom chrome with `\.appearsActive`.
- Avoid stacking your own blur or tint on system glass (HIG: Toolbars).

### 1.6 When AppKit is still needed

| Need | API | SwiftUI alternative? |
|---|---|---|
| App/file icons | [`NSWorkspace.icon(forFile:)`](https://developer.apple.com/documentation/appkit/nsworkspace/icon(forfile:)) | None. Wrap the `NSImage` in `Image(nsImage:)`. Cache aggressively. |
| Choose folders with options | [`NSOpenPanel`](https://developer.apple.com/documentation/appkit/nsopenpanel) | `fileImporter` ([doc](https://developer.apple.com/documentation/swiftui/view/fileimporter(ispresented:allowedcontenttypes:allowsmultipleselection:oncompletion:))) covers simple cases. Use `NSOpenPanel` for `canChooseDirectories`, `directoryURL`, and prompt text. |
| Reveal in Finder | [`NSWorkspace.activateFileViewerSelecting(_:)`](https://developer.apple.com/documentation/appkit/nsworkspace/activatefileviewerselecting(_:)) | None. |
| Move to Trash | [`NSWorkspace.recycle(_:completionHandler:)`](https://developer.apple.com/documentation/appkit/nsworkspace/recycle(_:completionhandler:)) or [`FileManager.trashItem(at:resultingItemURL:)`](https://developer.apple.com/documentation/foundation/filemanager/trashitem(at:resultingitemurl:)) | None. |
| Quick Look | SwiftUI [`quickLookPreview(_:)`](https://developer.apple.com/documentation/swiftui/view/quicklookpreview(_:)) (macOS 11) | Use `QLPreviewPanel` ([doc](https://developer.apple.com/documentation/quicklookui/qlpreviewpanel)) only if you want the floating Space-bar panel. |
| Open System Settings | [`NSWorkspace.open(_:)`](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:)) | `@Environment(\.openURL)` also works. |

Everything else (window, sidebar, toolbar, inspector, settings scene) stays in pure SwiftUI.

---

## 2. Architecture

### 2.1 Layout

```text
TruongCleaner.xcodeproj
  App target (SwiftUI, thin): scenes, views, @Observable view models
  Packages/CleanerKit            (local SwiftPM package, tools-version 6.4)
    CleanerCore       pure Foundation. Models, rules, risk levels, byte math. No UI.
    CleanerScanner    directory walking, sizing, dedupe of aliased paths
    CleanerActions    trash/delete with allow-list guards
    Tests/            Swift Testing
```

A local package with `// swift-tools-version: 6.4`, `platforms: [.macOS(.v26)]`, `swiftLanguageModes: [.v6]`, and `.treatAllWarnings(as: .error)` per target built and passed `swift test` on this Mac **[V]**. The package tests run with `swift test` or `xcodebuild test -destination 'platform=macOS'`. They need no simulator.

### 2.2 Observation and Swift 6.4 concurrency

- `@Observable @MainActor final class` compiled in Swift 6 language mode with warnings as errors **[V]**. Hold view models in `@State`. On macOS 27 SDKs `@State` is a macro that creates `@Observable` objects lazily, once (WWDC26 breakdown above).
- Xcode 26.2+ added the build settings **Approachable Concurrency** and **Default Actor Isolation = MainActor** for new projects ([Apple forums, 812598](https://developer.apple.com/forums/thread/812598); the underlying proposal is [SE-0466](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md)). Recommended split **[I]**: the app target uses default MainActor isolation. The scanner package uses `nonisolated` value types, `Sendable` results, and `@concurrent` or actor-isolated work so directory walks never run on the main actor. Heed the forum report that under MainActor default, a plain `nonisolated async` function can end up running on the main thread. Mark heavy functions `@concurrent` explicitly.
- Keep `-warnings-as-errors` and Swift 6 mode on from day one, as TruongCam does.

### 2.3 Scanner design lessons from an existing macOS cleaner

ClearDisk's public release notes are a free list of failure modes ([releases](https://github.com/bysiber/cleardisk/releases)). Relevant to design **[S]**:

- Full-volume scans caused 400-500% CPU spikes. It later used a conservative worker budget and ran scan phases sequentially.
- Retaining a node for every file grew memory into gigabytes. It switched to a shallow tree with accurate totals and on-demand deeper scans.
- APFS System/Data volume boundaries and `/var` vs `/private/var` aliases caused early termination and double counting.
- Treating `~` as a project root made `~/.cache` look like a build directory. Never match project types at the home root.
- Mark risk by the real cost of deletion. For example, an AI editor's whole Application Support folder holds chats and settings, so it is not a cache.

### 2.4 Swift Testing vs XCTest on macOS 27

- Swift Testing: `@Test`, `#expect`, parameterized tests, and exit tests. `swift test` on this Mac printed "Testing Library Version: 2084" and passed a parameterized test **[V]**.
- Xcode 27 defaults to interoperability, so XCTest helpers and Swift Testing can share assertions. The recommended mode is "Complete" (cross-framework issues become errors) per [WWDC26 session 267 "Migrate to Swift Testing"](https://developer.apple.com/videos/play/wwdc2026/267/) (summarized at [WWDCNotes](https://wwdcnotes.com/documentation/wwdc26-267-migrate-to-swift-testing/)).
- Swift Testing does not cover UI automation or performance metrics. Use XCTest/XCUIAutomation for those ([WWDC25 344](https://developer.apple.com/videos/play/wwdc2025/344/)).
- **Recommendation:** Swift Testing for all logic (scanner, rules, formatting, guards). Skip UI tests in v1. TruongCam uses XCTest, so this is a deliberate departure. The reason is parallel parameterized tests for the rule tables and one fewer framework mix.
- Hosted CI: package tests are headless and run on the `xcode-27` image. I did not test GUI tests (XCUITest) on hosted runners **[unverified]**.

### 2.5 App size of a zero-dependency SwiftUI app (measured)

Built from the appendix sample (NavigationSplitView + Form + Charts + glass), `-O`, stripped, ad-hoc signed, on this Mac **[V]**:

| Artifact | Size |
|---|---|
| Stripped Mach-O (arm64) | **134 KB** |
| `.app` on disk (`du -sk`, 4 KB blocks) | **140 KB** |
| ZIP via `ditto -c -k --keepParent` | **35 KB** |
| DMG via `hdiutil create -format UDZO` | **54 KB** |

`otool -L` shows the app links SwiftUI, Charts, AppKit and Foundation from the OS and the Swift runtime from `/usr/lib/swift`. Nothing is embedded, because the deployment target is above macOS 10.14.4. A real app adds icon, assets, and localizations (typically hundreds of KB to a few MB).

Sparkle 2.10.1's framework is **3.0 MB on disk**, of which 408 KB is XPC services that a non-sandboxed app can remove ([Sparkle docs](https://sparkle-project.org/documentation/)) **[V]** for the size, **[S]** for the removal note. So Sparkle is roughly 20x the whole bare app.

---

## 3. Permissions

### 3.1 macOS 27 changes that hit a cleaner directly

From Apple's macOS 27 beta 3 release notes (section "System Integrity Protection", via [gist copy](https://gist.github.com/applch/9b53eeb96c4cf097efa2cb5c9bd53b97); explained at [macos-tahoe.com](https://macos-tahoe.com/blog/macos-27-app-data-containers-access-denied-operation-not-permitted-fix-2026/), third-party) **[S]**:

- Access to **other developer teams' app data containers and app group containers** no longer prompts. It is **denied by default** and managed in Privacy & Security. Same-team access is unaffected.
- **XProtect** may restrict access to app data that malware commonly targets.
- Under "TCC": **apps can no longer access the local TCC database directly**.
- `launchd` no longer loads plist files that carry the quarantine attribute. This matters if you ever install a LaunchAgent/LaunchDaemon plist from a downloaded bundle.

Extra detail from a security researcher: macOS 27 extends the `com.apple.macl` protection to chosen **non-sandboxed apps' `~/Library/Application Support/<name>` folders**. The first-wave list covers Discord, Chrome, Brave, Edge, Firefox, Ledger Live, Exodus and Wasabi. It lives in `sandboxd` and can be updated through XProtect ([wojciechregula.blog](https://wojciechregula.blog/post/golden-gate-appdata-protection/); single researcher's analysis, **moderate**). The listed paths are Application Support, not `~/Library/Caches`.

Design implications **[I]**:

- Sandboxed apps' caches (`~/Library/Containers/*/Data/Library/Caches`) will return `EPERM` without FDA. Handle `EPERM` per path, show "needs access" rows, and never crash or report size 0 silently.
- A cleaner is a legitimate FDA use case. Apple's own FDA statement names backup apps as the purpose ([Apple news, 2026-10-02](https://developer.apple.com/news/?id=p6zjojqw)). The macOS-tahoe.com guide says disk analyzers are also a reasonable FDA use (third-party opinion).

### 3.2 Detecting Full Disk Access

There is **no public API** to ask "do I have FDA". Apple engineers have said so repeatedly (for example [forums 741289](https://developer.apple.com/forums/thread/741289): only an Endpoint Security client gets a definitive failure code, which a cleaner should not use).

| Probe | Status on macOS 27 |
|---|---|
| Read `~/Library/Application Support/com.apple.TCC/TCC.db` | **Dead.** The user TCC DB moved into a `ProtectedSystem` container ([Apple forums 834560](https://developer.apple.com/forums/thread/834560), snippet; [researcher post](https://wojciechregula.blog/post/golden-gate-appdata-protection/)). ClearDisk 2.3.2 dropped it: "does not exist on macOS 27" and now reads the system TCC DB if present, then falls back to listing Safari, Mail and Stocks app data ([release notes](https://github.com/bysiber/cleardisk/releases)). |
| Read `~/Library/Safari/` | **Unreliable.** An Apple Developer Forums thread titled "Detecting Full Disk Access on macOS" reports that on macOS 27 the read fails with access denied even when FDA is granted, giving a false negative ([thread 841091](https://developer.apple.com/forums/thread/841091); I saw only the search snippet because the forum blocks automated fetches). A later reply in the same thread says the answer to three related questions "remains no". |
| Read `/Library/Preferences/com.apple.TimeMachine.plist` | Old community probe ([thread 114452](https://developer.apple.com/forums/thread/114452)). Not tested on 27. |

**Recommendation [I]:**

1. Treat detection as a **tri-state** (granted / not granted / unknown), never a hard gate.
2. Probe several protected locations (Safari, Mail, Stocks as ClearDisk does; plus one container path) and grant "likely granted" if any read succeeds.
3. Make the **real work the source of truth**: when a scan path returns `EPERM`, mark that path as needing access and offer the FDA flow.
4. Provide a "Check again" button and re-probe on `NSApplication.didBecomeActiveNotification`, since the user returns from System Settings.

**Deep link.** `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` is used by the open-source [disktree](https://github.com/tobi/disktree/blob/main/crates/disktree-core/src/access.rs) (line 20). Open it with `NSWorkspace.shared.open(url)`. I did not open System Settings on this Mac, so I did **not** confirm that the URL still lands on the FDA pane in macOS 27 **[unverified]**. Keep a fallback that opens System Settings and shows instructions.

The app only appears in the FDA list after it has attempted a protected read in many cases, and can also be added with the "+" button. Commonly observed; **not verified this session**.

### 3.3 Policy risk: Apple will add controls to FDA

Apple Developer News, 2026-10-02 ("Updates to Full Disk Access in macOS"): Apple says some developers use FDA in risky ways, it will "introduce additional controls", and users should only be able to grant it through "very explicit user action". It cites AI agents as a growing risk. No dates or mechanics are given ([Apple](https://developer.apple.com/news/?id=p6zjojqw); coverage: [MacRumors](https://www.macrumors.com/2026/10/02/apple-announces-macos-full-disk-access-changes/)). Treat this as a signal. Keep the FDA flow isolated in one module so it is cheap to change, and keep a useful non-FDA mode (user-owned caches, Trash, Downloads, Xcode/dev caches).

### 3.4 Privileged helper (`SMAppService.daemon`)

**What the API is [V].** All of these exist with `introducedAt: 13.0`: [`SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice), [`daemon(plistName:)`](https://developer.apple.com/documentation/servicemanagement/smappservice/daemon(plistname:)), [`register()`](https://developer.apple.com/documentation/servicemanagement/smappservice/register()), [`openSystemSettingsLoginItems()`](https://developer.apple.com/documentation/servicemanagement/smappservice/opensystemsettingsloginitems()), and [`NSXPCConnection.setCodeSigningRequirement(_:)`](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)).

**Mechanics [S].**

- Bundle layout: helper executable in the app, a launchd plist at `Contents/Library/LaunchDaemons/`, and `daemon(plistName:)` points at it ([Microsoft Procexp helper README](https://github.com/microsoft/ProcexpForMac/blob/main/Helper/README.md), [alienator88/HelperToolApp](https://github.com/alienator88/HelperToolApp)).
- The user must approve the daemon in **System Settings > General > Login Items & Extensions**. There is no password prompt from the API; developers must direct users to Settings (HelperToolApp README; Procexp README).
- Peer validation on the helper side should check the connecting client's code signature. The Procexp helper does this with `SecCodeCheckValidity`; its release builds require both the app identifier and the Developer ID Team ID.
- Do not add the restricted entitlement `com.apple.developer.service-management.managed-by-launchd` without a provisioning profile. Per the Procexp README the app then fails to launch.
- Pitfalls reported on the Apple forums for macOS 26: launch-constraint violations when upgrading a daemon ([795022](https://developer.apple.com/forums/thread/795022)), and a daemon launching from the first path it was registered at ([853652](https://developer.apple.com/forums/thread/853652)). An approved daemon stays running if the user disables the app in Background Activity in one setup ([848726](https://developer.apple.com/forums/thread/848726)).

**Does it work without a paid Developer ID? Precise answer.**

| Signing | Registers via `SMAppService.daemon`? | Evidence |
|---|---|---|
| Ad-hoc (`codesign -s -`) | **No evidence it works; the one explicit statement says no.** | Microsoft's Procexp README: "SMAppService requires a stable signing identity". It adds that an ad-hoc build "can run without the helper but cannot register it" **[S, single source]**. A Sequoia forum thread reports an unsigned daemon showing "Item from unidentified developer" and not running even when enabled ([757463](https://developer.apple.com/forums/thread/757463), snippet). |
| Persistent self-signed identity | Works **locally** for development. | Procexp README describes a persistent self-signed identity plus separate user approval for dev builds. Not trusted on other users' Macs **[I]**. |
| Apple Development cert (free or paid account) | Works for development on your own machine. | Trilemma's sample says to configure a Development certificate, and says "Sign to Run Locally" is unsupported because its requirements cannot securely identify app and helper ([SwiftAuthorizationSample](https://github.com/trilemma-dev/SwiftAuthorizationSample), written for SMJobBless but the signing-identity point carries over **[I]**). I found no source that confirms a free-account Apple Development cert works for **distributed** daemons. |
| Developer ID + notarization | Yes. This is the supported distribution path. | HelperToolApp's debugging checklist and the Procexp README. |

Why ad-hoc cannot work for XPC pinning **[V + I]**: I checked that an ad-hoc app's designated requirement is `cdhash H"..."`, and that it changed when I added one file and re-signed (`eeb148...` to `acb19f...`). A client-side `setCodeSigningRequirement` can then only pin a cdhash or an identifier string. A cdhash changes every build, and an identifier-only check would let any process claiming that identifier talk to a root daemon. Apple's own wording on the requirement API is in the doc link above.

**Recommendation.** No helper in v1. For root-owned targets, list them as "needs administrator" and skip them. If they matter later, options in order: (a) Developer ID + `SMAppService.daemon`; (b) a per-action administrator prompt via `NSAppleScript` `do shell script ... with administrator privileges` (an inference; **I did not test it on macOS 27**, and Apple may restrict it).

### 3.5 Sandbox vs non-sandbox, and the App Store

Mac App Store rule 2.4.5 ([App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), text fetched 2026-11-06):

- (i) Apps must be **appropriately sandboxed**, and should use appropriate macOS APIs when modifying data stored by other apps.
- (iii) No auto-launch or login code without consent.
- (v) **No request for root privileges** and no setuid.
- (vii) Updates must go through the Mac App Store. No other update mechanism.

Together these exclude a helper, Sparkle, and broad disk access. FDA does not lift sandbox restrictions on a sandboxed app (my recollection of how the sandbox and TCC layer; **not re-verified this session**). **Recommendation: not sandboxed, outside the Mac App Store.** ClearDisk, a comparable cleaner, ships a Developer ID signed, notarized DMG with Sparkle and a Homebrew tap ([releases](https://github.com/bysiber/cleardisk/releases)).

---

## 4. Distribution: without vs with a paid Apple Developer account

### 4.1 No paid account (ad-hoc signing)

**Gatekeeper behavior [S].**

- Apple says macOS verifies the Developer ID signature and, by default since Catalina, requires notarization; first open of a downloaded app prompts for approval ([Apple Support: Safely open apps on your Mac](https://support.apple.com/en-us/102445)).
- **macOS 15 removed the Control-click > Open override.** The user must try to open the app, then go to **System Settings > Privacy & Security** and click **Open Anyway** ([MacRumors, 2024-08-06](https://www.macrumors.com/2024/08/06/MACOS-SEQUOIA-GATEKEEPER-SECURITY-CHANGE/); [AppleInsider](https://appleinsider.com/inside/macos-sequoia/tips/whats-changed-in-runtime-protection-for-macos-sequoia)). I found no evidence that macOS 26 or 27 changed this flow back, but I did not click through it on 27.
- `xattr -d com.apple.quarantine /Applications/TruongCleaner.app` (or `xattr -cr`) clears the quarantine flag for that app. Files fetched by `curl`/`gh` generally carry no quarantine attribute **[background knowledge, not tested]**.
- Apple silicon will not run arm64 code without at least an ad-hoc signature (Homebrew's statement in [brew#20755](https://github.com/Homebrew/brew/issues/20755)). Xcode/the linker adds one automatically. I confirmed `codesign -dv` shows `Signature=adhoc`, `TeamIdentifier=not set`, and `spctl --assess --type execute` says **rejected** for the ad-hoc app **[V]**. The rejection is expected. It is why "Open Anyway" is needed.
- One anecdotal report: on macOS 26, a quarantined binary stayed blocked after `xattr -d` because the block was cached at the policy level, and only a re-sign at a new path fixed it ([openai/codex#17447](https://github.com/openai/codex/issues/17447); a Developer-ID-signed but un-notarized CLI, single report). Treat "clear quarantine" as best effort and document "Open Anyway" first.

**Costs of ad-hoc that are easy to miss:**

1. **Permissions may not survive updates [I].** An ad-hoc app's designated requirement is its cdhash, which changes every build [V]. TCC records a code requirement per grant, so an updated ad-hoc build can look like a different app and need FDA re-granted. This is inference from the requirement, and widely reported in practice, but I did not test TCC behavior across builds.
2. **Library validation.** Sparkle's setup guide warns that with Hardened Runtime library validation on, an ad-hoc-signed app may not be allowed to load Sparkle. Not using Hardened Runtime avoids it ([Sparkle docs](https://sparkle-project.org/documentation/)). Notarization requires Hardened Runtime, so this trade flips when you get a Developer ID.
3. No helper (3.4).

### 4.2 Homebrew

- Homebrew 5.0.0 (2025-11-12) deprecated casks without codesigning/notarization and said it will disable all `homebrew/cask` casks that fail Gatekeeper in **September 2026** ([brew.sh](https://brew.sh/2025/11/12/homebrew-5.0.0/), [brew#20755](https://github.com/Homebrew/brew/issues/20755)). Homebrew 6.0.0 (2026-06-11) said this remained on track ([brew.sh](https://brew.sh/2026/06/11/homebrew-6.0.0/)). A gist from October 2026 reports the `chromedriver` cask was disabled on 2026-09-01 for failing Gatekeeper ([gist](https://gist.github.com/agilous/fbfb2163e0406e5ff849d35a9c152428)). `--no-quarantine` is deprecated ([brew#20755](https://github.com/Homebrew/brew/issues/20755)).
- Consequence **[I]**: **an ad-hoc-signed app cannot enter the official cask repo**. A personal tap can still list it, but users must run `brew trust <tap>` first (tap trust, Homebrew 6.0.0) and still hit Gatekeeper on first launch. A tap helps discoverability, not Gatekeeper.
- Homebrew 7.0.0 (2026-09-13) supports macOS 27 on Apple silicon at Tier 1 ([brew.sh](https://brew.sh/2026/09/13/homebrew-7.0.0/)). Cask `postflight` blocks are deprecated in favor of declared `postflight_steps` (third-party taps get warnings until 2027-12-11).

### 4.3 With a paid account (Developer ID + notarization)

- Membership requirement: Developer ID certificates and notarization require the paid Apple Developer Program. A forum answer says members can notarize Mac apps at no extra fee ([forums 746992](https://developer.apple.com/forums/thread/746992)); see [Developer ID](https://developer.apple.com/support/developer-id). I did not fetch the current annual fee **[unverified]**; check [developer.apple.com/programs](https://developer.apple.com/programs/enroll).
- CI notarization: `xcrun notarytool submit <file> --key AuthKey.p8 --key-id ... --issuer ... --wait`, then `xcrun stapler staple`. Wrapper actions exist ([Apple-Actions/notarize](https://github.com/Apple-Actions/notarize)); I recommend calling `notarytool` directly to keep the pipeline SHA-pinned and auditable.
- Secrets: Developer ID certificate (.p12, base64) + password, App Store Connect API key (.p8) + key ID + issuer ID. Import the certificate into an **ephemeral keychain** and delete it at job end (pattern shown in [MacSai RELEASING.md](https://github.com/iliyami/MacSai/blob/main/docs/RELEASING.md)).
- **Risk to check early:** one signing-action README says `notarytool` does not support **Individual** App Store Connect API keys and needs a **Team** key ([ehl-macos-signing-action](https://github.com/EsionHsrahLatigid/ehl-macos-signing-action), single third-party source **[S, weak]**). If you enroll as an individual, test API-key notarization on day one. `notarytool` also accepts Apple ID + app-specific password + team ID **[background knowledge]**.
- Result: no "Open Anyway", official Homebrew cask possible, stable code identity (Team ID), privileged helper possible, and Sparkle key rotation possible (Sparkle docs: rotation needs a Developer ID signature).

### 4.4 DMG

- `hdiutil create -volname TruongCleaner -srcfolder dist/ -format UDZO -ov out.dmg` works and produced a 54 KB DMG for the test app **[V]**. Put an `/Applications` symlink next to the app in the source folder. [Sparkle docs](https://sparkle-project.org/documentation/) recommend that.
- `create-dmg` (Homebrew) only adds window layout and background art. It is optional.
- Sparkle consumes DMG, ZIP, tarballs, Apple Archives, and installer packages (same doc), so one artifact can serve both humans and the updater. A plain ZIP from `ditto -c -k --keepParent` is simplest and smallest (35 KB for the test app **[V]**). Sparkle docs say that in a ZIP the app should be the only item.

### 4.5 Sparkle 2 with ad-hoc signing

- Current release: **Sparkle 2.10.1, published 2026-10-25** (GitHub API **[V]**). 2.10 requires macOS 12+ ([upgrading doc](https://sparkle-project.org/documentation/upgrading/)).
- **Yes, Sparkle works for ad-hoc apps.** Sparkle's source (`SUUpdateValidator.m`, `2.x` branch) says a bundle update passes if the old and new **EdDSA public keys match and are valid** (this "allows change of Code Signing identity"), or if the old and new code-signing identities match. Its error text says: if no Apple certificate is available, "adhoc signing can be used at minimum" **[V, source read]**. The new app must still carry a code signature.
- A third-party project (Ebb) documents end-to-end tests on macOS 27 with Sparkle 2.10.1: ad-hoc 0.0.1 to ad-hoc 0.1.0 installed, with a valid signature and no quarantine on the result, and a ZIP altered by one byte after signing was rejected with error 4005 ([docs/updates.md](https://github.com/lucasnsaraujo/ebb/blob/main/docs/updates.md); single source, **moderate**). It also notes that Sparkle removes the quarantine flag from the new bundle, so updates do not re-prompt Gatekeeper. Sparkle's `SUFileManager.m` contains quarantine-removal code **[V, source read]**.
- **Key-loss risk [S].** Per Ebb and Sparkle's docs, EdDSA key rotation requires a Developer ID signature. Without one, losing the private key means every user must reinstall by hand. Keep an offline backup.
- **GitHub-hosted appcast.** Publish `appcast.xml` as a release asset and point `SUFeedURL` at `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml`. GitHub redirects that to the newest non-draft, non-prerelease release (Ebb doc). Release tags with a hyphen (for example `v1.2.0-beta.1`) should be marked prerelease so installed copies ignore them.
- **Key handling in CI.** `generate_keys` stores the private key in the login keychain by default. For CI, export it (`-x`) and store as an Actions secret, then call `generate_appcast --ed-key-file`. Sparkle's docs say to keep signing keys off the machine that hosts the files. Ebb generates the key in Sparkle's raw format without the keychain.
- Hardened Runtime off (ad-hoc) means library validation does not block Sparkle. If you later notarize, enable Hardened Runtime and sign Sparkle's nested helpers correctly (Sparkle docs recommend Xcode's archive/export for that).
- Optional hardening: `SURequireSignedFeed` + `SUVerifyUpdateBeforeExtraction` (signed feeds are validated as of Sparkle 2.9; same doc).

**Update mechanism, trade-offs:**

| Option | Pros | Cons |
|---|---|---|
| **Sparkle 2** (recommended) | In-app install, EdDSA verification, quarantine removed on update, GitHub-hosted | +3 MB (minus 408 KB if you strip XPC services), one dependency, key custody |
| Notify-only checker (`URLSession` to `api.github.com/repos/.../releases/latest`, compare versions, open release page) | Zero dependency, tiny, no key custody | User re-downloads and repeats "Open Anyway" and FDA steps every update |
| Homebrew tap only | Familiar to developers | Needs `brew trust`; Gatekeeper still blocks an unsigned app; not usable by non-technical users |

---

## 5. GitHub Actions

### 5.1 Runner labels, images, cost (as of 2026-11-06)

| Label | OS | Xcode | Arch | Source |
|---|---|---|---|---|
| **`xcode-27`**, `xcode-27-xlarge` | macOS 27.0.1 (26A434), image 20261026.0314.1 | **27.1 (default, 27A9275)**, 27.2 RC (27B48), **27.0 (27A266a) at `/Applications/Xcode_27.app`** | arm64 only | [image readme](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md) **[V]** (fetched today) |
| `macos-26` (also `macos-latest`), `macos-26-xlarge` | macOS 26.6.2 (25G83), image 20261026.0455.2 | 26.6 (default) down to 26.0.1 | arm64 | [image readme](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md) |
| `macos-26-intel`, `macos-26-large`, `macos-latest-large` | macOS 26 | n/a | x64 | [runner docs](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) |
| `macos-15`, `macos-15-xlarge`; `macos-15-intel`, `macos-15-large` | macOS 15 | n/a | arm64 / x64 | same |
| `macos-14` | macOS 14 | n/a | x64 | **Retired 2026-11-02** (same doc) |

- **There is no `macos-27` label.** macOS 27 is reached only through `xcode-27`. The Xcode image was in public preview on macOS 26, moved to macOS 27 on 2026-09-10 ([changelog](https://github.blog/changelog/2026-09-10-xcode-27-runner-image-now-runs-on-macos-27/)), and became generally available on 2026-10-15 ([changelog](https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/)). The runner docs table still shows a "preview" badge, which is stale.
- Each Xcode image supports **one major Xcode version** (same changelog). Minor versions are all installed.
- Standard arm64 macOS runner: **3 cores (M1), 7 GB RAM, 14 GB SSD** ([runner docs](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)).
- **Cost:** standard hosted runners are **free in public repositories**. Private repos draw from included compute ($12/month on GitHub Free, $18 on Pro and Team) at **$0.062 per macOS minute**, rounded up per job ([Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions), [runner pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing)). A 10-minute macOS job on a private repo costs about $0.62, so the $12 Free-plan allowance covers roughly 190 macOS minutes (about 19 such jobs) a month. `xlarge` (5-core M2 Pro) is $0.102 per minute and is always billed.
- **Pin the Xcode version.** The image's default is Xcode 27.1 while this Mac runs 27.0. For reproducible warnings-as-errors, select `/Applications/Xcode_27.0.app` or accept 27.1 deliberately. A newer SDK can introduce new deprecation warnings that fail the build. The image also ships a macOS 27.2 SDK with 27.2.
- Homebrew itself runs routine macOS 27 tests on `xcode-27` ([Homebrew 7.0.0](https://brew.sh/2026/09/13/homebrew-7.0.0/)), which is a reasonable maturity signal. Intel macOS runners retire in autumn 2027 per the same post.

### 5.2 CodeQL for Swift on Xcode 27

- GitHub changelog, 2026-10-19: with Xcode 27 installed, **traced extraction is unavailable** for C/C++, C#, Go, Java, Kotlin and Swift. **CodeQL does not support Swift 6.4 on any platform.** Intel Mac support is deprecated in mid-December 2026. For Swift, the advice is to pin macOS 26 and Xcode 26 or earlier ([changelog](https://github.blog/changelog/2026-10-19-codeql-changes-for-macos-27-xcode-27-and-swift-6-4/), [discussion #210464](https://github.com/orgs/community/discussions/210464)).
- One community write-up warns of "silent zero" results: CodeQL exits 0 with no alerts while the SARIF contains extraction errors. Check the SARIF if you try it (discussion #210464, community post, **moderate**). [CodeQL system requirements](https://codeql.github.com/docs/codeql-overview/system-requirements) say macOS 27 support is limited to Apple silicon and build mode `none`. Swift has no `none` mode (discussion #210464).
- This matches the TruongCam repo, which runs CodeQL on workflows only ([README](https://github.com/iant4093/TruongCam)).

**Options for TruongCleaner:**

| Option | Trade-off |
|---|---|
| **A. CodeQL on workflows only** (recommended default) | Same as TruongCam. No Swift SAST. Rely on the compiler (strict concurrency, warnings as errors), SwiftLint, tests, and Xcode analyzer. |
| B. Separate CodeQL Swift job on `macos-26` + Xcode 26.6 | Gives Swift scanning. Requires the source to compile on Swift 6.3 and the macOS 26 SDK: no Swift 6.4-only syntax, no macOS 27-only APIs, and local package `swift-tools-version` of 6.3 or lower. Extra CI minutes. Silent-zero risk. |

I recommend A for now and revisiting B once GitHub announces Swift 6.4 support.

### 5.3 Pipeline shape (from the TruongCam reference)

Reuse the TruongCam structure [S, from its README]: `runs-on: xcode-27`, SHA-pinned actions with weekly Dependabot, actionlint + zizmor + gitleaks, SwiftLint, Swift 6 strict concurrency, warnings as errors, build provenance attestations, and `SHA256SUMS`. Adaptations for a macOS app:

1. Build Release with `xcodebuild` using `CODE_SIGNING_ALLOWED=NO`, then ad-hoc sign the bundle explicitly with `codesign --force --deep --sign -` (or sign nested code inside-out; avoid `--deep` once Sparkle is embedded, sign its helpers individually).
2. Verify with `codesign --verify --strict` and check `lipo -archs` equals `arm64`.
3. Package `TruongCleaner-<version>.dmg` (and a ZIP for Sparkle if you want both) plus `SHA256SUMS`, then attest the files.
4. Sign the Sparkle archive with `generate_appcast --ed-key-file` and upload `appcast.xml`.
5. Optional dSYM zip for crash symbolication, as TruongCam does.
6. Add a "Developer ID" job gated on the presence of the secrets for later; keep it disabled until then.

---

## 6. Recommendations with trade-offs

### 6.1 Minimum deployment target: macOS 26 vs 27

| | macOS 26.0 (recommended) | macOS 27.0 |
|---|---|---|
| Liquid Glass APIs | All of them [V] | Same set. **No new SwiftUI glass API in the 27 SDK** [V]. |
| New in 27 that you would want | Nothing required. `GeometryProxy.concentricCornerRadii` and `NSGlassEffectView.effectIsInteractive` can be `#available`-gated if you want them. | Slightly simpler code if you adopt them. |
| Look on macOS 27 | Same automatic look and slider response, because it is driven by the SDK you build with and the OS you run on [S] | Same |
| Reach | Tahoe plus Golden Gate. TelemetryDeck data via one aggregator put macOS 26 at 86.0% of tracked installs in the week of 2026-07-27, before macOS 27 shipped on 2026-09-14 ([source](https://www.aboutchromebooks.com/macos-version-distribution-statistics/), **moderate**). Current macOS 27 share is unknown to me. | Golden Gate only. macOS 27 requires Apple silicon (Intel dropped; Homebrew 7.0.0 post). |
| CI | Build and test on `xcode-27`. Optionally also build on `macos-26` + Xcode 26.6 to prove the 26 floor. | Only `xcode-27` |
| Risk | You must test on a macOS 26 machine or VM. No macOS 26 hardware is attached to the CI image for UI checks. | A big cut in audience for no API benefit |

**Recommendation: macOS 26.0 floor, arm64 only, built with Xcode 27.** Revisit when a macOS 27-only API becomes valuable (none today).

### 6.2 Signing path

| | Ad-hoc now | Developer ID later |
|---|---|---|
| Cost | $0 | Paid annual membership (amount not verified) |
| First launch | Download, drag to Applications, try to open, **System Settings > Privacy & Security > Open Anyway**, or `xattr -d com.apple.quarantine` | Normal "downloaded from the Internet" prompt |
| Official Homebrew cask | **Not possible** (Gatekeeper requirement since Sept 2026) | Possible |
| Privileged helper | **No** (3.4) | Yes |
| FDA grant across updates | Likely needs re-grant after each update [I] | Stable (Team ID + bundle ID) |
| Sparkle | Works. Key loss = manual reinstall for everyone | Works. Key rotation possible |
| CI secrets | None (matches TruongCam's "no Apple certificate" policy) | Certificate, API key, ephemeral keychain |
| Trust signal | Weak. Checksums + build attestations help | Strong |

**Recommendation:** ship ad-hoc with clear in-README first-run steps. Design the code so signing is only a pipeline concern: keep the bundle ID and Sparkle EdDSA key stable from release 1, so a later move to Developer ID is an update, not a new app. If the owner expects to distribute widely or wants the helper, buy the membership before the first public release, because switching later changes the app's code identity and its privacy grants.

### 6.3 Update mechanism

Sparkle 2 with EdDSA, appcast at `releases/latest/download/appcast.xml`. Strip Sparkle's XPC services (not sandboxed). Back up the EdDSA key offline. If the owner wants a hard zero-dependency policy like TruongCam, use the notify-only checker and accept manual re-installs.

### 6.4 Test framework

Swift Testing in the local package for all logic, run with `swift test` in CI. No XCTest unless UI automation is added. Keep `swiftLanguageModes: [.v6]` and `treatAllWarnings(as: .error)`.

---

## 7. Gaps and things I could not verify

- **WWDC26 session pages** on developer.apple.com (including 269 "What's new in SwiftUI") did not render in my fetch tool. WWDC26 details come from a third-party write-up and from the installed SDK, which is primary for API availability.
- **Apple's macOS 27 release notes** were read from a gist copy of the beta 3 notes, not the live page. Final wording may differ.
- **Apple Developer Forums** pages (FDA detection 841091, TCC 834560, and others) blocked automated fetches. I relied on search snippets, so the exact probe path in thread 841091 is not confirmed.
- **Not tested on macOS 27:** the FDA deep link, the "Open Anyway" click path, TCC behavior across ad-hoc rebuilds, `NSAppleScript` admin prompts, GUI tests on hosted runners, and the Individual vs Team API key question for `notarytool`.
- **The annual Developer Program fee** was not fetched.
- **"Mac App Store sandbox + FDA"** relationship is stated from memory.
- `UIDesignRequiresCompatibility` (the Liquid Glass opt-out key) is said by a third-party skill file to end at SDK 27 ([farkasseb/liquid-glass-skill](https://github.com/farkasseb/liquid-glass-skill)). I did not verify this and the app does not need the opt-out.

---

## Appendix A: the sample I compiled (macOS 26 target, Swift 6, warnings as errors)

Command: `swiftc -disable-sandbox -parse-as-library -swift-version 6 -warnings-as-errors -O -target arm64-apple-macosx26.0 main.swift -o tc_26`. (`-disable-sandbox` was needed only because my tool environment already runs inside a sandbox; the `@Observable` macro plugin cannot start there otherwise.)

```swift
import SwiftUI
import Charts
import Observation
import AppKit

@Observable @MainActor final class Model {
    var query = ""
    var selection: Category? = .caches
    var showInspector = false
    var items: [Item] = [Item(name: "Xcode DerivedData", bytes: 12_000_000_000),
                         Item(name: "Caches", bytes: 3_000_000_000)]
}
struct Item: Identifiable, Sendable { let id = UUID(); let name: String; let bytes: Int64 }
enum Category: String, CaseIterable, Identifiable { case caches, logs, apps; var id: String { rawValue } }

struct ContentView: View {
    @State private var model = Model()
    @Namespace private var ns
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.appearsActive) private var appearsActive
    var body: some View {
        NavigationSplitView {
            List(Category.allCases, selection: $model.selection) { c in
                Label { Text(c.rawValue) } icon: { IconTile(symbol: "trash", color: .blue) }.tag(c)
            }
            .searchable(text: $model.query, placement: .sidebar)
        } detail: {
            Form {
                Section("Storage") {
                    Chart(model.items) { BarMark(x: .value("GB", $0.bytes), y: .value("Name", $0.name)) }
                    LabeledContent("Total", value: "15 GB")
                }
                GlassEffectContainer(spacing: 12) {
                    HStack {
                        Button("Clean") {}.buttonStyle(.glassProminent)
                        Button("Review") {}.buttonStyle(.glass)
                        Button("Clear") {}.buttonStyle(.glass(.clear))
                        Text("x").padding()
                            .glassEffect(.regular.tint(.blue).interactive(), in: .capsule)
                            .glassEffectID("a", in: ns)
                    }
                }
            }
            .formStyle(.grouped)
            .backgroundExtensionEffect()
            .inspector(isPresented: $model.showInspector) { Text("Inspector") }
            .toolbar {
                ToolbarItem { Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: "/tmp")]) } }
                ToolbarSpacer(.fixed)
                ToolbarItem { Button("Inspect") { model.showInspector.toggle() } }
            }
        }
        .opacity(appearsActive ? 1 : 0.8)
    }
}
```

(`IconTile` is defined in section 1.3. `reduceTransparency` is read but unused here; use it to swap custom backgrounds.)

## Appendix B: key sources

Apple: [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) · [HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials) · [Updates to Full Disk Access (2026-10-02)](https://developer.apple.com/news/?id=p6zjojqw) · [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) · [Safely open apps on your Mac](https://support.apple.com/en-us/102445) · [WWDC26 267](https://developer.apple.com/videos/play/wwdc2026/267/) · [WWDC26 269](https://developer.apple.com/la/videos/play/wwdc2026/269/) · [macOS 27 release notes (copy)](https://gist.github.com/applch/9b53eeb96c4cf097efa2cb5c9bd53b97)

GitHub: [Xcode 27 image GA](https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/) · [CodeQL changes for macOS 27 / Xcode 27 / Swift 6.4](https://github.blog/changelog/2026-10-19-codeql-changes-for-macos-27-xcode-27-and-swift-6-4/) · [xcode-27 image readme](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md) · [macos-26 image readme](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md) · [Hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) · [Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)

Sparkle: [Documentation](https://sparkle-project.org/documentation/) · [SUUpdateValidator.m](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SUUpdateValidator.m) · [Ebb updates.md (ad-hoc case study)](https://github.com/lucasnsaraujo/ebb/blob/main/docs/updates.md)

Homebrew: [5.0.0](https://brew.sh/2025/11/12/homebrew-5.0.0/) · [6.0.0](https://brew.sh/2026/06/11/homebrew-6.0.0/) · [7.0.0](https://brew.sh/2026/09/13/homebrew-7.0.0/) · [brew#20755](https://github.com/Homebrew/brew/issues/20755)

Reference repo: [iant4093/TruongCam](https://github.com/iant4093/TruongCam)
