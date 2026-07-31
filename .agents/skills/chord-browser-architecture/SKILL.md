---
name: chord-browser-architecture
description: Architecture, module layout, data model, and project structure for the Chord Browser macOS app built on WKWebView. Covers the layered architecture (Core/Persistence/Engine/Extensions/Store/UI), the Space/Tab/Pane data model, web view pooling, content blocking, extensions, and all established patterns.
---

# Chord Browser Architecture & Project Knowledge

This skill contains distilled knowledge from README.md, BROWSER_SPEC.md, and CHECKPOINT.md for the Chord Browser project.

## Project Overview

Chord Browser is a native macOS browser built in Swift on `WKWebView`. It replicates Arc's interaction model (Spaces, vertical tabs, command bar, ephemeral tabs, split view, Little Arc) while running on Apple's WebKit engine. All spec milestones (M1–M7) plus native content blocking are shipped and verified.

**Status:** 423 tests in 68 suites. Schema **v11**. `./scripts/prepush.sh` green. Post-spec additions have landed on top of M1–M7 (BROWSER_SPEC §4.9): multiple windows, folders, per-Space history, per-site permissions, web notifications, YouTube ad skipping, General settings.

## Project Layout

```
BrowserApp/              @main, AppDelegate, debug overlay (Cmd+Ctrl+P, DEBUG only)
Packages/Sources/
  BrowserCore/           Value types + pure logic (ranking, sweep policy). Foundation only.
  BrowserPersistence/    GRDB, migrations, row types, mappers
  BrowserEngine/         The ONLY package importing WebKit (with BrowserExtensions)
  BrowserExtensions/     WKWebExtension host + .crx unpack
  BrowserStore/          TabStore (+Spaces/+Sweep/+CommandBar/+Split/+LittleArc/+Restore/+Find)
  BrowserUI/             SwiftUI views + command bar and Little Arc panels. Never WebKit.
  BrowserTestSupport/    Fakes, TabBuilder, TestHTTPServer
Packages/Tests/
  Browser*Tests/         Unit tests per package
  BrowserE2ETests/       Full stack: real engine + real SQLite + real HTTP
docs/adr/                Why the non-obvious calls were made
scripts/                 prepush.sh (local CI), soak.sh (memory soak harness), reset-data.sh
```

## Core Data Model (from BROWSER_SPEC §3.2)

```swift
struct Space: Identifiable, Codable {
    let id: UUID
    var name: String
    var iconSymbol: String          // SF Symbol name or emoji
    var gradient: [ColorHex]        // 2–3 stops, drives sidebar theming
    var dataStoreID: UUID           // -> WKWebsiteDataStore(forIdentifier:)
    var sortIndex: Int
}

enum TabPlacement: Codable {
    case pinned(order: Int, homeURL: URL?)      // Favourites grid; never auto-closed
    case bookmarked(order: Int, homeURL: URL)   // Pinned tabs; never auto-closed
    case ephemeral(order: Int)                  // auto-closed after idle window
}

struct Tab: Identifiable, Codable {
    let id: UUID
    var spaceID: UUID
    var placement: TabPlacement
    var panes: [Pane]               // count 1 = normal, 2...4 = split view
    var focusedPaneID: UUID
    var lastAccessedAt: Date
    var createdAt: Date
}

struct Pane: Identifiable, Codable {
    let id: UUID
    var url: URL
    var title: String
    var faviconData: Data?
    var interactionState: Data?     // WKWebView.interactionState, for restore
    var widthFraction: Double       // split-view sizing, sums to 1.0 per tab
}
```

## Key Architecture Patterns

### Layering (§3.1)
```
UI layer      → SwiftUI views + AppKit windows
Store layer   → Observable app state, commands
Engine layer  → WebViewPool, DataStore registry, ExtensionHost, ContentBlocker
Persistence   → SQLite — spaces, tabs, history
```

UI never touches `WKWebView` directly. It talks to the Store; the Store owns the Engine.

### Spaces & Data Isolation (§3.3)
- Each Space gets its own `WKWebsiteDataStore(forIdentifier: space.dataStoreID)` — fully isolated cookies, localStorage, cache.
- Data stores created lazily, cached by Space ID.
- Deleting a Space calls `WKWebsiteDataStore.remove(forIdentifier:)`.

### Web View Pooling (§3.4)
- Max ~12 live web views. Evict LRU: capture `interactionState`, tear down view, keep model.
- Revive from `interactionState` — no reload.
- Evict aggressively on memory pressure.
- Never instantiate a `WKWebView` for a tab not yet viewed (lazy restore).

### Extensions (M7, §4.7)
- Per-Space `WKWebExtensionController` (ADR 011). One controller per Space, config keyed by Space's `dataStoreID`.
- `BrowserExtensions` is a second WebKit importer (alongside `BrowserEngine`).
- MV3 only. No MV2 shims.
- `.crx`/`.xpi` unpack to `~/Library/Application Support/Browser/Extensions/`.

### Content Blocking (§4.8)
- Compiles EasyList + EasyPrivacy into `WKContentRuleList`s. ~137k rules chunked at 50k per list.
- Network + cosmetic filtering. Standard CSS `:has()` supported.
- Cannot block YouTube ads (scriptlet injection needed, out of scope).
- On by default. Weekly refresh from upstream lists.

## Windows vs. the world (post-M7)

`WindowState` holds per-window state (sidebar, sheets, find, **and** selection:
`activeSpaceID`, `selectedTabID`); `TabStore` holds the shared world (tabs,
Spaces, folders, persistence). Pass the window explicitly — `TabStore`'s
no-argument forms mean "the primary window" and are migration scaffolding.
A mutation removing tabs or Spaces calls `reconcileWindows(excluding:)`; "is this
tab in use?" must ask **every** window (`isSelectedByAnyWindow`), which is what
stops the sweep archiving a page another window is showing. Window layout
persists (`v9_window_layout`).

## Site permissions and notifications (post-M7)

- Camera / microphone / notifications: one model, decided per **(Space, origin,
  kind)**, asked once, remembered, revocable in Settings → Privacy & Data.
  `SitePermissionKind` / `SitePermissionPrompt` / `SitePermissionRecord` live in
  `BrowserCore` (WebKit-free). Schema `v10_site_permissions`, re-scoped by
  `v11_site_permissions_per_space`. **ADR 014.** Never restore a blanket grant.
- Web notifications are an in-page shim (`NotificationBridge`) over
  `UNUserNotificationCenter` — public `WKWebView` has no notification hook. Two
  message handlers: `chordNotifyShow` (one-way) and `chordNotifyPermission`
  (with-reply; `op: query` reads without prompting, `op: request` may prompt).
  **Not Web Push.** **ADR 015.**
- Two permission layers stack: ours per site, macOS's per app. Both must be green.
- **Entitlements differ between Debug and Release.** Hardened Runtime (Release
  only) gates the mic behind `com.apple.security.device.audio-input`, not the
  sandbox's `com.apple.security.device.microphone`. Declare both.

## In-page monitors (the pattern)

When WebKit reports nothing, the answer here has consistently been a user script,
never SPI: audio playback (ADR 008), screen sharing (ADR 012), notifications
(ADR 015), YouTube ads (ADR 013). All are installed on the **per-view**
`WKUserContentController` and removed in `LiveWebView.tearDown()`; each JS side
uses a `window.__chord*` singleton guard because `atDocumentStart` can run more
than once per document.

## Known Traps & Hard-Won Lessons

### WebKit
- `layer.cornerRadius` + `masksToBounds` on `WKWebView` causes artifacts. Use a container `NSView`.
- `WKWebView`'s default UA has no `Version/` or `Safari/` token — must set `applicationNameForUserAgent`.
- `WKFindResult` reports only `matchFound` — no total/index. "3 of 12" not buildable.
- `decidePlaceholderPolicy` is iOS-only, does not exist on macOS.
- `WKProcessPool` deprecated in macOS 12 — process sharing follows the data store now.
- Apple's `url-filter` engine rejects disjunctions in regex patterns.
- Content rule list compile completion handler runs on main queue — semaphore-blocked main thread deadlocks. Use async/await.
- Compiling the whole 137k-rule set at once hits an uncatchable signal-6 abort. Must chunk at 50k.
- `WKMediaCaptureType` covers camera and microphone only — no display capture, so no "share this tab".
- Public `WKWebView` has no notification hook (`WKUIDelegate.h`) and no Web Push.
- AV1 decodes in **software** here: macOS reserves the hardware path for Safari, so `mediaCapabilities…powerEfficient` is false for AV1 and sites drop to VP9. Not the UA, not fixable in app code.
- `config.preferences.setValue(true, forKey: "managedMediaSourceEnabled")` is set by **KVC string key** — no typed accessor exists. It is the one spot outside §11's rule; if WebKit drops the key it raises `NSUnknownKeyException` while building the configuration, and no test covers it.

### SwiftUI / AppKit
- A SwiftUI view-level `.keyboardShortcut` beats a menu item with the same key silently.
- A focused `TextField` consumes Return and ignores Cmd+Return entirely.
- `onDrag`'s `NSItemProvider` delivers zero bytes via pasteboard — use `beginDraggingSession` with `NSPasteboardItem`.
- A `WKWebView` registers for dragged types itself; AppKit picks the deepest registered view under cursor, so SwiftUI `onDrop` always loses to the page.
- Any NSPanel must size itself from content and say so twice — `setContentSize` after `contentViewController` assignment.
- `onAppear` fires only once on a reused panel. Use a present token for reset/focus.
- Focus must be requested repeatedly for ~200ms on panel because it races the view update.

### Build / Test
- `swift test` runs unsandboxed — cannot verify entitlement-dependent features.
- Never `cp` the GRDB database — use `.backup`. Restoring a main file beside a newer WAL corrupts it.
- `os.Logger` logs are not retrievable via `log show`/`log stream` on this machine. Use screenshots.
- The app is a `Window`, NOT a `WindowGroup` — a group spawns a second window on external URLs.

## Sandboxed App Data Path

`~/Library/Containers/com.rizal.browser/Data/Library/Application Support/Browser/`

## Performance Budgets (§6.1)

| Metric | Target | Hard ceiling |
|---|---|---|
| App process RSS (excl. content processes) | < 150 MB | 250 MB |
| Total footprint, 5 live tabs | < 1.2 GB | 1.8 GB |
| Idle CPU, window visible, no animation | < 0.5% | 1% |
| Cold launch to first interactive frame | < 400 ms | 800 ms |
| Space switch to first painted frame | < 100 ms | 200 ms |

## Three Tab Tiers (§4.1a)

1. **Favourites** (`.pinned`) — icon grid at top. Sweep-exempt. Has optional `homeURL`.
2. **Pinned** (`.bookmarked`) — list section between favourites and ephemeral. Sweep-exempt. Has required `homeURL`. Collapsible per-Space header.
3. **Ephemeral** (`.ephemeral`) — the loose tabs swept after idle window (default 12h).

Close on a favourite/pinned tab **unloads** it (tears down web view) but keeps the sidebar entry and favicon.

## Feature Flags

`FeatureFlags` struct was **deleted** (§7.4) — both extensions and content blocking are always on.

## Post-M7 Follow-ups (non-spec, ask user before building)

- Per-site content-blocking whitelist / disable toggle
- Runtime settings toggle for content blocking
- Per-domain User-Agent override map (§9.6) — the UA setting is global today
- Full Instruments GUI trace (SwiftUI body counts, Energy Log)
- Sidebar scroll fps measurement
