---
name: chord-browser-architecture
description: Architecture, module layout, data model, and project structure for the Chord Browser macOS app built on WKWebView. Covers the layered architecture (Core/Persistence/Engine/Extensions/Store/UI), the Space/Tab/Pane data model, web view pooling, content blocking, extensions, and all established patterns.
---

# Chord Browser Architecture & Project Knowledge

This skill contains distilled knowledge from README.md, BROWSER_SPEC.md, and CHECKPOINT.md for the Chord Browser project.

## Project Overview

Chord Browser is a native macOS browser built in Swift on `WKWebView`. It replicates Arc's interaction model (Spaces, vertical tabs, command bar, ephemeral tabs, split view, Little Arc) while running on Apple's WebKit engine. All spec milestones (M1–M7) plus native content blocking are shipped and verified.

**Status:** 621 tests in 94 suites. Schema **v14**. `./scripts/prepush.sh` green. Post-spec additions have landed on top of M1–M7 (BROWSER_SPEC §4.9): multiple windows, folders, per-Space history, per-site permissions, web notifications, YouTube ad skipping, General settings, the password vault (V1–V7), private windows, per-domain UA rules, file-backed logging, Arc-style Peek, user-renamed tabs, **`window.open()` popups as real web views** (keeps the `window.open()` reference; `window.close()` closes the tab — fixes OAuth logins like Shopee's Google button; ADR 018), and **swipe-to-close** (rightward swipe on a pane with no back history closes the tab / Little Chord; WebKit's native gesture untouched, on-by-default flag in Settings → General → Gestures, `BackSwipeMonitor` in Engine).

## Project Layout

```
BrowserApp/              @main, AppDelegate, debug overlay (Cmd+Ctrl+P, DEBUG only)
Packages/Sources/
  BrowserCore/           Value types + pure logic (ranking, sweep policy). Foundation only.
  BrowserLogging/        AppLog: every line → os.Logger + rotating file. Foundation + os only.
  BrowserSecrets/        Keychain + LocalAuthentication. The vault's secret half.
  BrowserCrypto/         Security + CryptoKit. Extension-bundle signature verification.
  BrowserPersistence/    GRDB, migrations, row types, mappers
  BrowserEngine/         The ONLY package importing WebKit (with BrowserExtensions)
  BrowserExtensions/     WKWebExtension host + .crx unpack + signature verdict stamping
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
- **Apple's runtime is a subset, and each big extension trips a different missing piece.** Unimplemented: `offscreen`, `sidePanel`, `nativeMessaging`, `webRequestAuthProvider`, blocking `webRequest`, scriptlet injection; `declarativeNetRequest` caps ~50k rules/list. WebKit *silently drops* unimplemented permissions, so the API object is `undefined` and an extension touching it at startup dies with `WKWebExtensionContextErrorDomain` code 6 (background content failed to load) — which presents as a popup spinning forever. AdBlock fails on the rule cap; **Bitwarden fails on `offscreen`** (2026-07-31). Diagnosis procedure is in the maintenance skill.
- An extension **popup pins its window's sidebar open** while visible (`WindowState.isSidebarHeldOpen`) — the popover is anchored to the sidebar-header button, so an auto-hiding sidebar closes it mid-use.
- `.crx`/`.xpi` unpack to `~/Library/Application Support/Browser/Extensions/` as `Extensions/<slug>.zip` plus a `<slug>.verification` sidecar.

### Extension signature verification (ADR 017)
- **Warn-but-install.** `BrowserCrypto.ExtensionSignatureVerifier` verifies the CRX2/CRX3 signature at install; unsigned/unknown-signer bundles still install but are flagged (orange warning icon on the row, an install-time message, and an enable-time confirmation). Verified-with-pinned-key → `.trusted`, verified-with-embedded-key → `.verified`, tampered → `.tampered`, plain ZIP → `.unsigned`.
- **The verdict is persisted** (`Extensions/<slug>.verification`), because the CRX header that proves it is stripped at install.
- **Pinned key set is empty today** (no extension store); the API takes `pinnedKeys:` so a store key slots in later.
- CRX3 verification is real: it parses the protobuf `CrxFileHeader`/`SignedData`, verifies the RSA-SHA256 proof over `signed_header_data`, and checks the ZIP against `SignedData.sha256_with_rsa`. ECDSA-only headers → `.unsupported`.
- `BrowserCrypto` is the second Security/CryptoKit importer (after `BrowserSecrets`).

### Content Blocking (§4.8)
- Compiles EasyList + EasyPrivacy into `WKContentRuleList`s. ~137k rules chunked at 50k per list.
- Network + cosmetic filtering. Standard CSS `:has()` supported.
- Cannot block YouTube ads (scriptlet injection needed, out of scope).
- On by default. Weekly refresh from upstream lists, **per-list independent**: each list has its own content-hash identifier, its own `lastRefresh` timestamp, and a failure fetching one defers only that list (it keeps its last good set and retries next launch). Never-refreshed slots fall back to the seed so blocking never silently shrinks.

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

## Password vault (V1–V6, ADR 016)

`docs/design/password-vault.md` is the source of truth. The load-bearing rules:

- **Metadata in SQLite (`credential`, v12), password in the Keychain** via
  `BrowserSecrets` — one of two Security importers (`BrowserCrypto`, ADR 017, is
  the other). A secret must never reach the database, a log, or observable state
  (`CredentialSavePrompt` has no password field by design).
- **Exact origin equality** for every fill — scheme + host + port, never
  parent-domain. `CredentialOrigin.Policy` is `.strict` in the app; only
  `E2EHarness` relaxes it.
- **No fill without a user gesture**, and the origin is re-checked inside the
  engine against the live `WKWebView` at the moment of writing.
- **Fill through the prototype value setter** — `el.value =` is swallowed by
  React's value tracker.
- **Invisible fields are never touched**, which is what defeats Google's decoy
  password field and GitHub's honeypots in one rule.
- Detection is `PasswordFormMonitor` (collects, pierces open shadow roots,
  re-runs on mutation) → `LoginFormClassifier` (decides, pure, corpus-tested).
- **V7 lock is fully shipped** (do not re-flag it): `VaultLockPolicy` +
  `VaultLockTimeout` (idle presets, default 15 min), `TabStore+VaultLock`
  (`lockVault`/`unlockVault`/`refreshVaultLock`), the Sleep/screen-lock /
  fast-user-switch observers in `AppDelegate.attachVaultLockObservers`, the
  "Vault locked / Lock Now / timeout picker" section in `PasswordsSettings`, and
  `VaultLockTests`. All password-vault phases are built.

## In-page monitors (the pattern)

When WebKit reports nothing, the answer here has consistently been a user script,
never SPI: audio playback (ADR 008), screen sharing (ADR 012), notifications
(ADR 015), YouTube ads (ADR 013). All are installed on the **per-view**
`WKUserContentController` and removed in `LiveWebView.tearDown()`; each JS side
uses a `window.__chord*` singleton guard because `atDocumentStart` can run more
than once per document. YouTube's ad selectors are a recurring maintenance item —
see the `chord-browser-youtube-ads` skill for the upkeep procedure.

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
- **Element fullscreen must not find the WKWebView AutoLayout-governed** (ADR 019). When a page element goes fullscreen WebKit replaces the web view with a placeholder, moves it into its own fullscreen window, and moves it back (`WKWebView.fullscreenState`, KVO-compliant — observe it and re-anchor on `.notInFullscreen`). A web view whose size is owned by constraints from a higher ancestor (SwiftUI hosting) comes back at a `0×0` frame and the fullscreen video renders **black until the app is relaunched** (webkit.org/b/313802, macOS 26). The web view is therefore installed frame + `autoresizingMask = [.width, .height]`, never pinned with constraints. A future overlay must go on the container, not the web view.

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
- `os.Logger` logs are not retrievable via `log show`/`log stream` on this machine — but `AppLog` mirrors every line to `Application Support/Browser/Logs/browser.log` (rotating, 5 MB), so read that file instead of using screenshots. Screenshots are only for visual verification.
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
- ~~Per-domain User-Agent override map (§9.6)~~ **Done 2026-08-01** —
  `UserAgentOverride` (Core), the rules editor in `GeneralSettings.perDomainRules`,
  most-specific-subdomain matching in `WebKitEngine.setUserAgent`, persisted via
  `Preferences`, covered by `UserAgentRulesTests`/`UserAgentStoreTests`/e2e
- ~~Extension signature verification~~ **Done 2026-08-07 (warn-but-install, ADR 017)**
- ~~Per-list content-blocker refresh~~ **Done 2026-08-07**
- ~~Single source of truth for the Safari UA version token~~ **Done 2026-08-07**
- Full Instruments GUI trace (SwiftUI body counts, Energy Log)
- Sidebar scroll fps measurement
