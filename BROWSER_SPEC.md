# Project Spec — Custom WebKit Browser for macOS

> Hand this whole file to Claude Code. Section 0 is the kickoff prompt; everything
> after it is reference material Claude Code should read before writing code, and
> re-read at the start of each milestone.

---

## 0. Kickoff Prompt

```
Read BROWSER_SPEC.md in full before writing any code.

We are building a native macOS browser in Swift on top of WKWebView. It is a
personal Arc replacement — Arc's interaction model, WebKit's engine.

Start with Milestone 1 only (Section 8). Do not scaffold future milestones.
Do not add features that are not in the current milestone's scope.

Before you write code:
1. Confirm the toolchain (Section 2) and tell me if anything is unavailable.
2. Propose the module/file layout for Milestone 1 and wait for my approval.

Then implement Milestone 1, and stop. I will review and tell you to continue.

Working agreements are in Section 11. Follow them strictly — especially the rule
about not inventing WebKit APIs. If you are unsure whether an API exists or what
its signature is, say so and ask rather than guessing.
```

---

## 1. Product Definition

A single-window macOS browser. Chromium-free. The feature set is deliberately
small and closed — it replicates only what I actually use in Arc:

| # | Feature | One-line definition |
|---|---------|---------------------|
| 1 | Vertical tabs | Sidebar tab list, drag-reorderable, collapse-to-icons with hover-expand |
| 2 | Spaces | Named workspaces, each with isolated cookies/storage and its own tab set |
| 3 | Ephemeral tabs | Unpinned tabs auto-close after a configurable idle window (default 12h) |
| 4 | Command bar | Cmd+T overlay: navigate, search, jump to open tab, run commands |
| 5 | Split view | 2–4 web views tiled in one tab, resizable, persisted |
| 6 | Little Arc | Links from other apps open in a floating panel, promotable to a real tab |
| 7 | Extensions | WKWebExtension-hosted MV3 extensions, loaded from unpacked directories |

**Explicit non-goals.** No AI features. No Easels/Notes. No cross-device sync in
v1. No iOS target. No Windows/Linux. No Chrome Web Store integration. No
telemetry of any kind.

---

## 2. Toolchain and Constraints

- **Language:** Swift 6, strict concurrency enabled.
- **UI:** SwiftUI for the sidebar, lists, and command bar. AppKit
  (`NSWindow`, `NSPanel`, `NSViewRepresentable`) wherever SwiftUI cannot reach —
  window management, non-activating panels, raw scroll-phase events.
- **Engine:** WebKit / `WKWebView`. **Never** shell out to Chromium, CEF, or
  Electron.
- **Deployment target:** macOS 15.4. This is a hard floor, set by
  `WKWebExtension` availability. Do not add fallback paths for older macOS.
- **Persistence:** SQLite via GRDB, or Core Data — propose one in Milestone 1 and
  justify it. Do not use both.
- **Dependencies:** minimize. Every third-party package needs a one-line
  justification before it is added.
- **Build:** Xcode project, buildable from CLI via `xcodebuild`. Keep it
  buildable at every commit.

---

## 3. Architecture

### 3.1 Layering

```
┌─────────────────────────────────────────────────┐
│  UI layer      SwiftUI views + AppKit windows   │
├─────────────────────────────────────────────────┤
│  Store layer   Observable app state, commands   │
├─────────────────────────────────────────────────┤
│  Engine layer  WebViewPool, DataStore registry, │
│                ExtensionHost, ContentBlocker    │
├─────────────────────────────────────────────────┤
│  Persistence   SQLite — spaces, tabs, history   │
└─────────────────────────────────────────────────┘
```

The UI layer must never touch `WKWebView` directly. It talks to the store; the
store owns the engine layer. This matters because web views are expensive,
crash-prone, and need pooling — that logic cannot be spread across views.

### 3.2 Core model

```swift
struct Space: Identifiable, Codable {
    let id: UUID
    var name: String
    var iconSymbol: String          // SF Symbol name
    var gradient: [ColorHex]        // 2–3 stops, drives sidebar theming
    var dataStoreID: UUID           // -> WKWebsiteDataStore(forIdentifier:)
    var sortIndex: Int
}

enum TabPlacement: Codable {
    // "pinned" is the Favourites icon grid (historical name). "bookmarked" is
    // Arc's Pinned-tabs list. Both are exempt from the idle sweep and both carry
    // a homeURL — the URL the tab returns to (double-click a favourite tile, or
    // click a selected Pinned row). See §4.1a.
    case pinned(order: Int, homeURL: URL?)         // Favourites grid; never auto-closed
    case bookmarked(order: Int, homeURL: URL)      // Pinned tabs; never auto-closed
    case ephemeral(order: Int)                     // auto-closed after idle window
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

Notes:
- `Pane` is the unit that owns a `WKWebView`. A tab with one pane is the normal
  case; split view is just a tab with more panes. Do **not** model split view as
  a separate type — that duplication is the single most common design mistake
  here.
- `interactionState` is `WKWebView`'s opaque restore blob (macOS 12+). Persist it
  on tab deactivation, not on every navigation.

### 3.3 Spaces and data isolation

Each Space gets its own `WKWebsiteDataStore(forIdentifier: space.dataStoreID)`.
This gives fully isolated cookies, localStorage, and cache per Space as
first-class WebKit API — two Google accounts logged in simultaneously with no
profile switching.

Requirements:
- Data stores are created lazily on first use and cached in a registry keyed by
  Space ID.
- A web view belongs to the Space it was created in: resolve the Space from the
  tab, never from the current selection, and tear the view down before moving a
  tab between Spaces. See ADR 006.
- Deleting a Space must call `WKWebsiteDataStore.remove(forIdentifier:)` to
  reclaim disk. Prompt before doing so; it is irreversible.
- One Space may be marked `isPrivate`, using `.nonPersistent()` instead.

### 3.4 Web view pooling

Do not hold a live `WKWebView` for every pane. Rules:

- Max ~12 live web views. Beyond that, evict least-recently-used panes: capture
  `interactionState`, tear down the view, keep the model.
- Reviving an evicted pane restores from `interactionState` — no full reload.
- All web views in a Space share one `WKProcessPool` and one
  `WKWebViewConfiguration` template.
- Implement `webViewWebContentProcessDidTerminate` on day one. Content processes
  die routinely; without this, a single bad page appears to hang the app.

---

### 3.5 Module layout

Ship as local Swift Package Manager targets, not one flat app target. The
boundaries are enforced by the compiler, which is the only enforcement that
survives a year of changes.

```
BrowserApp/              // thin: App, main window, wiring only
Packages/
  BrowserCore/           // Space, Tab, Pane, value types. Zero imports.
  BrowserPersistence/    // schema, migrations, repositories. Imports Core.
  BrowserEngine/         // WebKit isolation layer. Imports Core.
  BrowserStore/          // observable app state + commands. Core+Engine+Persistence.
  BrowserExtensions/     // WKWebExtension host. Imports Core + Engine. (M7)
  BrowserUI/             // SwiftUI views. Imports Core + Engine + Store.
  BrowserTestSupport/    // fakes, fixtures, builders. Test-only.
```

Implemented as one `Packages/Package.swift` with a target per entry, not one
manifest each — identical compile-time enforcement, one file to maintain. See
ADR 005 for `BrowserStore`, which 3.1 requires but the original list omitted.

Rules:
- `BrowserCore` imports nothing but Foundation. No WebKit, no SwiftUI. If a type
  in Core needs to know about `WKWebView`, the design is wrong.
- **`BrowserUI` must not import WebKit.** It receives an opaque view from Engine
  via a `NSViewRepresentable` factory (`AnyWebSurface`). This single rule is what
  will let you swap, wrap, or mock the engine later. UI does import Engine — it
  has to, to name the surface type — but no `WK*` type appears in Engine's
  public interface.
- Dependencies flow downward only. No target imports a target above it. If you
  need an upward call, define a protocol in the lower target and inject.
- Each package has its own test target.

### 3.6 Seams and dependency injection

Every boundary that touches the OS gets a protocol. Not for ceremony — for
testability and for surviving WebKit API churn.

```swift
protocol WebEngine {
    func makeView(for pane: Pane, in space: Space) -> AnyWebSurface
    func evict(paneID: UUID) async -> Data?      // returns interactionState
    func liveViewCount() -> Int
}

protocol TabRepository {
    func load(spaceID: UUID) async throws -> [Tab]
    func save(_ tabs: [Tab]) async throws
}

protocol Clock { var now: Date { get } }         // ephemeral sweep is testable
protocol ExtensionHost { ... }
```

- Concrete types (`WebKitEngine`, `SQLiteTabRepository`, `SystemClock`) live in
  their own packages and are the only things that import the framework.
- Inject through a single `AppEnvironment` struct constructed at launch and
  passed down. No singletons, no service locator, no `@EnvironmentObject` for
  services — SwiftUI environment is for view concerns only.
- Every protocol has a fake in `BrowserTestSupport`. Sweep logic, ranking, and
  restore should be testable with zero WebKit involvement.

### 3.7 Errors, logging, diagnostics

- Typed errors per package (`PersistenceError`, `EngineError`). No bare
  `NSError`, no stringly-typed failures.
- Use `os.Logger` with one subsystem and a category per package. No `print`.
  Signposts around launch, Space switch, and restore so Instruments traces are
  readable without instrumentation work later.
- User-facing failures degrade gracefully: a corrupt tab row is skipped and
  logged, never a launch crash. Persistence must be defensive — it is the one
  subsystem where a bug costs the user data rather than a reload.

---

## 4. Feature Specs

### 4.1 Vertical tabs (sidebar)

- Sections top-to-bottom: Favourites grid, Pinned tabs, new-tab affordance,
  ephemeral tabs, Space switcher (on the bottom bar).
- Drag to reorder within a section, drag across sections to change placement,
  drag onto a Space in the switcher to move between Spaces.
- Collapsed state shows favicons only; hovering the collapsed sidebar expands it
  as an overlay without shifting web content.
- Sidebar background carries the active Space's gradient with a material overlay.

### 4.1a Favourites and Pinned tabs (three tiers)

Three tab tiers, matching Arc, all per-Space:

- **Favourites** — an icon grid at the top (`TabPlacement.pinned`). Exempt from
  the idle sweep.
- **Pinned** — a list section between the favourites grid and the New Tab
  affordance (`TabPlacement.bookmarked`), under a collapsible header showing a
  count. Collapse state is per-Space and persisted (a window preference in
  `UserDefaults`, not the schema). Exempt from the sweep.
- **Ephemeral** — the loose tabs the sweep may close (§4.3).

Both non-ephemeral tiers carry a **home URL** — the URL the tab was pinned at:

- **Return to home**: double-click a favourite tile, or click an already-selected
  Pinned row. Context menu: *Return to Pinned URL*.
- **Re-home**: *Set Current Page as Pinned URL* replaces the home with the
  current page.
- **Close keeps the entry** (Cmd+W, the × button, "Close Tab"): a favourite or
  Pinned tab is **unloaded, not removed** — the live web view is torn down but the
  sidebar entry stays, keeping its favicon. A favourite keeps its current page
  (state captured, restored on reopen); a Pinned tab returns to its home URL.
- **Pin/unpin**: *Pin to Favourites* / *Pin Tab* / *Add to Favourites* / *Unpin*,
  or by dragging between sections. Pinning captures the current URL as the home;
  re-pinning preserves an existing home. A favicon carried onto a reset home is
  kept only when it matches the home's origin (favicons are per-origin).

### 4.2 Spaces

- Switch via sidebar click, `Cmd+1...9`, or two-finger horizontal swipe.
- Swipe must track the trackpad continuously and rubber-band at the ends. This
  requires raw `NSEvent` scroll-phase handling (`.began` / `.changed` / `.ended`
  with `momentumPhase`), driving animation progress directly — not a discrete
  `NSGestureRecognizer`. Hand off to a spring on release.
- Space switch animates the sidebar gradient between color sets.

### 4.3 Ephemeral tabs

- A background sweep runs every 5 minutes.
- Any `.ephemeral` tab whose `lastAccessedAt` is older than the idle window
  (default 12h, user-configurable, "never" allowed) is closed.
- Closed tabs go to a recoverable archive (last 100), searchable from the command
  bar. Never hard-delete on sweep.
- Favourites and Pinned tabs are exempt (only `.ephemeral` is swept).
  Audio-playing tabs are exempt — detected by injected
  user script, since no public WebKit API reports playback (ADR 008). The
  selected tab is also exempt.

### 4.4 Command bar

- `Cmd+T` and `Cmd+L` both open a non-activating `NSPanel` centered over the
  window. They differ only in what Return does: `Cmd+T` opens the result in a
  **new tab**, `Cmd+L` navigates the **current** tab.
- Single input. Ranked results across: open tabs (all Spaces), history,
  bookmarks, commands, then raw URL / search-query fallback.
- Fuzzy scoring with recency weighting. Open tabs outrank history at equal score.
- A **complete typed address takes the top slot**, ahead of open tabs. A search
  query does not — there an open tab or a history hit is the better guess, so
  the fallback stays last.
- Every row states what Return will do to it ("Switch to Tab", "Go to Page",
  "Search"…). A result that switches Space must announce that before it happens,
  not after.
- Return acts per the mode above; `Cmd+Enter` forces a new tab from either mode;
  Esc dismisses. Choosing an already-open tab always switches to it rather than
  opening a duplicate.

### 4.5 Split view

- `Cmd+Shift+D` splits the focused tab. Up to 4 panes.
- **Dragging a sidebar tab onto the content area** splits the tab it lands on,
  adding the dragged tab's page as a pane. The dragged tab is *moved*, not
  copied — it stops being its own row. A drop onto a tab that already has 4
  panes is refused and the dragged tab is left untouched.
- Drag dividers to resize; `widthFraction` persists per tab.
- Each pane has independent focus, navigation, and back/forward history.
- Closing down to one pane converts the tab back to a normal tab.

### 4.6 Little Arc

- App registers as an HTTP/HTTPS handler in `Info.plist`.
- External link → borderless `NSPanel`, scale-and-fade in from cursor position.
- `Cmd+O` promotes it into a real tab in the active Space. Esc dismisses.
- Panel is independent of the main window and may appear when the main window is
  closed.

### 4.7 Extensions

- Host via `WKWebExtensionController` + `WKWebExtensionContext`, **one controller
  per Space** (ADR 011 — resolves §12; storage isolation lives on the
  controller's configuration and data store, so per-Space contexts on a shared
  controller would not isolate).
- Load from unpacked directories in
  `~/Library/Application Support/<App>/Extensions/`.
- Ship a small CLI or in-app helper to unpack a `.crx` into that directory. Do
  **not** attempt Chrome Web Store install flows — CWS blocks non-Chrome agents.
- MV3 only. Do not add MV2 shims.
- Surface extension toolbar popovers in the sidebar header.
- **Critical:** do not reimplement the WebExtensions API. Kagi's Orion did that
  and reached ~70% coverage after six years with a funded team. We use Apple's
  framework and accept its coverage gaps.

### 4.8 Content blocking (independent of extensions)

- Compile EasyList + EasyPrivacy into `WKContentRuleList` at first launch, cache
  the compiled list, recompile weekly.
- This is native, fast, and often removes the need for a blocking extension.
- **Network + cosmetic filtering.** Network rules (`||host^`, options, `@@`
  exceptions) drop requests; element-hiding rules (`##`/`###`, domain-scoped)
  become `css-display-none`. Standard CSS `:has()` is honoured — WebKit's
  selector engine compiles it, verified end-to-end — so container-hiding rules
  (hide the wrapper that _contains_ an ad) work. Proprietary procedural cosmetics
  (`:upward`, `:xpath`, `:-abp-`, scriptlets, …) are outside the declarative API
  and are dropped-and-counted, never mis-applied.
- **Scope limit (honest):** `WKContentRuleList` cannot run scriptlets by Apple's
  design, so first-party-served video ads (e.g. YouTube's) are _not_ blockable
  through this path. That would require a separate JS-injection engine, which is
  out of scope for the native approach.
- **Extension ad blockers do not substitute.** AdBlock/uBlock Origin block via
  `declarativeNetRequest`; their rule sets (~63k) exceed WebKit's ~50k limit and
  are rejected, and Apple's `WKWebExtension` offers no request-blocking or
  scriptlet injection. Chromium browsers (Arc/Brave/Chrome) and Orion (WebKit +
  its own extension runtime) can run them; this native-WebKit stack cannot. See
  CHECKPOINT "Ad-blocking & YouTube" for the full analysis and the two (large,
  out-of-scope) future options.

---

## 5. UI / Visual Direction

Match Arc's *interaction model and timings* exactly. Use our own visual identity
for assets.

- Web content sits in an inset card with rounded corners and a soft shadow on the
  Space-tinted background.
  **Known trap:** `layer.cornerRadius` + `masksToBounds` directly on a
  `WKWebView` causes artifacts and can drop the compositor fast path. Use a
  container `NSView` for clipping and draw the shadow on a sibling layer.
- **Frosted-glass chrome.** The sidebar (docked and floating) and the border
  frame around the card use `.ultraThinMaterial` over the Space-gradient tint.
  The window is non-opaque (`isOpaque = false`, clear background) so the material
  blurs the desktop behind it rather than a flat fill; the web content card stays
  opaque so pages are unaffected.
- Icons: SF Symbols only. Type: system font. Do not extract or reuse any Arc
  asset.
- Animations: SwiftUI springs. Expose all durations and spring parameters as
  named constants in one `Motion.swift` file so they can be tuned in one place.
- Respect Reduce Motion and Increase Contrast accessibility settings.

---

## 6. Performance and Memory

Efficiency is a primary goal, not a cleanup pass. The entire reason we are on
WebKit rather than a Chromium fork is that the engine is already the most
battery- and memory-efficient option on macOS. It is easy to squander that in the
app layer, so treat the budgets below as acceptance criteria, not aspirations.

### 6.1 Budgets

Measured on Apple Silicon, with 20 tabs across 3 Spaces, 5 of them live:

| Metric | Target | Hard ceiling |
|---|---|---|
| App process RSS (excl. content processes) | < 150 MB | 250 MB |
| Total footprint, 5 live tabs | < 1.2 GB | 1.8 GB |
| Idle CPU, window visible, no animation | < 0.5% | 1% |
| Idle CPU, window occluded | ~0% | 0.2% |
| Cold launch to first interactive frame | < 400 ms | 800 ms |
| Space switch to first painted frame | < 100 ms | 200 ms |
| Command bar open to input-ready | < 50 ms | 100 ms |
| Sidebar scroll / drag | 120 fps (ProMotion) | no dropped frames at 60 |

If a milestone lands over its ceiling, fixing it is part of that milestone — not
deferred to M6.

### 6.2 Web view lifecycle (the dominant cost)

Everything else is noise next to this. Each live `WKWebView` costs a content
process, a networking allocation, and GPU-backed layers.

- Cap live web views at 12. Evict LRU beyond that: capture `interactionState`,
  tear down the view, keep the model. Reviving restores from state — no reload.
- Evict aggressively on memory pressure. Subscribe to
  `DispatchSource.makeMemoryPressureSource` and drop to 3 live views on
  `.critical`, 6 on `.warning`.
- Never instantiate a `WKWebView` for a tab that has not been viewed. Restored
  sessions must be lazy: show title and favicon from the model, create the view
  on first activation.
- Suspend background tabs. Set `isMuted` where applicable, and rely on WebKit's
  own throttling for occluded views — but verify it is actually engaging rather
  than assuming.
- ~~Share one `WKProcessPool` per Space.~~ Obsolete: Apple deprecated
  `WKProcessPool` in macOS 12 and it "no longer has any effect". Process sharing
  follows the data store now. See ADR 004.
- Reuse a single `WKWebViewConfiguration` template; copying is cheaper than
  rebuilding, and rebuilding recompiles content rule lists.

### 6.3 Window occlusion

When the window is not visible, the app should approach zero CPU. Observe
`NSWindow.occlusionState` and, on becoming occluded: pause all timers, stop the
ephemeral sweep until visible, halt favicon fetching, and cancel any in-flight
animation drivers. This is the difference between a browser that costs you an
hour of battery and one that costs you nothing while minimized.

### 6.4 SwiftUI discipline

SwiftUI is the most likely source of accidental CPU burn in this project.

- Sidebar rows must be cheap and stable. Give every row a stable identity; never
  recompute favicons, colors, or formatted strings in `body`.
- Scope observation narrowly. A tab-title change must not invalidate the Space
  switcher or the web content view. Use fine-grained `@Observable` models rather
  than one god-object the whole tree observes.
- No timers driving `body`. The ephemeral sweep updates the model; the model
  triggers a diff. Do not poll.
- Prefer `LazyVStack` in a `ScrollView` over eager stacks for tab lists.
- Verify with Instruments' SwiftUI template that view-body counts stay flat while
  idle. A browser that redraws its sidebar 60 times a second while nothing
  happens is the failure mode to watch for.

### 6.5 Storage and I/O

- Persist tab state debounced (~2 s) and coalesced. Do not write on every
  navigation or scroll.
- `interactionState` blobs are large. Store them out-of-line, load on demand, and
  cap retention for archived tabs.
- Favicons: cache to disk keyed by origin, downsample to display size before
  storing, never hold full-size images in memory.
- History writes go through a serial background queue. Never block the main
  thread on SQLite.

### 6.6 Extensions and content blocking

- `WKContentRuleList` compilation is expensive (seconds, hundreds of MB
  transiently). Compile off the main thread, at first launch and on the weekly
  refresh only. Cache the compiled list. Never compile on window open.
- Each extension with a background service worker costs a process. Surface
  per-extension memory in the extensions UI so bad actors are identifiable.
- Prefer the native content rule list over a blocking extension wherever it
  suffices — it is dramatically cheaper than uBlock's runtime cost.

### 6.7 Measurement

- Add a debug overlay (`Cmd+Ctrl+P`) showing live web view count, total footprint,
  and main-thread frame time. Ship it disabled in release.
- Every milestone's smoke checklist includes a 30-minute soak: 20 tabs, 3 Spaces,
  repeated Space switching. Record footprint at start and end. Growth over the
  soak indicates a leak — investigate before moving on.
- Profile with Instruments (Allocations, Leaks, SwiftUI, Energy Log) at the end
  of M1, M3, and M7. Attach findings to the milestone review.
- Retain-cycle discipline: `WKWebView` delegates and `WKScriptMessageHandler` are
  classic leak sources. Use `weak` delegate references and
  `removeScriptMessageHandler` on teardown. Assert deallocation in tests.

---

## 7. Maintainability and Upgrade Path

This is a tool you intend to still be using in five years, maintained by one
person part-time. Optimize for the version of you that returns after six months
away.

### 7.1 Isolating WebKit

WebKit is the fastest-moving dependency and the one Apple changes without asking.
The **engine layer is the WebKit boundary**: `BrowserEngine` and — from M7 —
`BrowserExtensions` are the only packages that import it (amended by ADR 011,
which adds the extension host as a second WebKit importer rather than folding it
into `BrowserEngine`). Inside those packages, framework types must not leak
through the public interface — no `WKWebView`, `WKNavigationDelegate`, or
`WKWebExtensionContext` in any signature `BrowserUI` or `BrowserCore` can see.
Wrap them. The two engine-layer packages may share `WK*` types with each other
(the extension controller reaches the engine as an opaque
`ExtensionControllerHandle`); nothing WebKit-shaped crosses into Store or UI.

Concretely: when `WKWebExtension` gains APIs in a future macOS, or a delegate
method is deprecated, the change should touch one package and no view code. If
you find yourself editing SwiftUI files to accommodate a WebKit change, the
isolation has already broken — fix it there rather than proceeding.

### 7.2 Persistence and migrations

Schema changes are the most common way a personal tool eats its own data.

- Version the schema from day one, at v1, even though nothing has changed yet.
  Retrofitting versioning after the fact is the painful path.
- Migrations are sequential, forward-only, and each is a separate named function
  with a test that runs it against a fixture database from the prior version.
  Keep those fixtures in the repo permanently.
- Back up the database file before running any migration; keep the last three.
- Model types in `BrowserCore` are the in-memory shape. Persistence uses its own
  row types and maps between them. Do not persist `Codable` app models directly —
  the day you rename a field, every existing profile breaks.
- Never delete user data as part of a migration. Orphan it and log.

### 7.3 macOS version policy

Floor is 15.4 and stays there until a specific API justifies raising it. When
adopting anything newer, gate it behind a named capability check in one file
(`Capabilities.swift`) rather than scattering `if #available` through the
codebase. When the floor eventually rises, deleting the old branches should be a
grep for one symbol.

### 7.4 Feature flags

Everything behind a flag in a single `FeatureFlags` struct, defaulting off for
in-progress work. This is what lets you keep the browser usable while a
half-built split view sits on `main`. Flags for shipped features get deleted —
do not accumulate a graveyard.

### 7.5 Decision records

Keep `docs/adr/NNN-title.md`, one short file per non-obvious decision: why
`WKWebExtension` over a custom WebExtensions implementation, why per-Space data
stores, why the live-view cap is 12. Three paragraphs each. The value is entirely
for future-you asking "why is this weird?" — without them you will re-litigate
the same choices and sometimes reverse them wrongly.

Update the ADR when a decision changes. Never delete one; supersede it.

### 7.6 Code health

- Keep `BROWSER_SPEC.md` current. When behavior diverges from this document,
  update the document in the same commit. A stale spec is worse than none,
  because Claude Code will follow it.
- No file over ~400 lines. When a view or coordinator grows past that, it is
  doing two jobs.
- Public API of each package gets doc comments. Internals get comments only where
  the *why* is non-obvious — WebKit workarounds especially, with a link to the
  radar or forum post that explains the behavior.
- Dependencies pinned to exact versions. Review updates deliberately; a personal
  browser has no reason to float.
- CI (even just a local pre-push script): build all packages, run all tests, fail
  on warnings. Warnings-as-errors from day one, before there are any.

---

## 8. Milestones

Implement strictly in order. Stop after each and wait for review.

**Every milestone is gated on Section 6's budgets.** A milestone is not complete
until the 30-minute soak passes and footprint sits under the ceiling. Do not
carry performance debt forward — in a browser it compounds badly, and by M6 the
cause is unfindable.

**M1 — Browse.** One window, sidebar with a flat tab list, `WKWebView` per tab,
navigation, new/close tab, favicon + title. Persistence layer chosen and wired.
Process-termination recovery in place.
*Done when:* I can browse for an hour without touching another browser.

**M2 — Spaces.** Space model, per-Space `WKWebsiteDataStore`, switcher UI,
gradient theming, `Cmd+1...9`. Swipe gesture deferred to M6.
*Done when:* two Google accounts stay logged in simultaneously in two Spaces.

**M3 — Command bar + ephemeral tabs.** Cmd+T panel, fuzzy ranking, sweep timer,
archive.
*Done when:* this is my daily driver.

**M4 — Session restore + downloads.** `interactionState` persistence, full
restore on launch, `WKDownload` handling with progress UI.
*Done when:* force-quit and relaunch restores everything.

**M5 — Split view + Little Arc.** Multi-pane tabs, URL handler, floating panel.

**M6 — Polish.** Swipe-driven Space switching, cross-section drag-and-drop,
animation tuning pass, find-in-page, print, PDF viewing.

**M7 — Extensions.** `WKWebExtension` host, `.crx` unpack helper, popover
surfacing. Last on purpose — a bad extension week must not stall the project.

---

## 9. Known Hard Parts

Flag these early rather than discovering them late:

1. Rounded corners on `WKWebView` (see 5).
2. Continuous swipe gesture — raw scroll-phase, not a gesture recognizer (4.2).
3. Cross-section drag-and-drop with animated gap-opening.
4. Content process termination and reload-on-crash.
5. Keychain/autofill behaves inconsistently in `WKWebView` versus Safari. Do not
   attempt to force parity; document what works.
6. ~2% of sites are Chrome-only tested. Add a per-domain user-agent override map
   rather than a global spoof.

---

## 10. Testing

- Unit tests for: fuzzy ranking, ephemeral sweep eligibility, split-view fraction
  math, model codable round-trips.
- Integration test: create Space → set a cookie → switch Space → assert cookie
  absent. Done twice: at the data-store level, and end-to-end through a real
  page (`BrowserE2ETests`).
- End-to-end suite: real `WKWebView`, real SQLite, real HTTP from a localhost
  test server. No fakes. This is the layer that catches wiring mistakes unit
  tests cannot see — it found the duplicate script-handler crash in ADR 008.
- Manual smoke checklist per milestone, kept in `SMOKE.md` and updated as
  features land.
- No UI snapshot tests. They will be worthless while the visual layer churns.

---

## 11. Working Agreements

- **Never invent WebKit API.** If unsure whether a symbol, initializer, or
  delegate method exists, or what its exact signature is, stop and ask. Do not
  produce plausible-looking WebKit code that does not compile. This is the single
  most important rule in this document.
- Keep the project compiling at every commit.
- ~~One milestone per branch.~~ Superseded after M4: a single `main` with linear
  history, one commit per milestone. The per-milestone branches were never
  reviewed separately or merged — they were just older pointers on one line, and
  keeping them implied a review flow that does not exist for a solo project.
  Small, reviewable commits with real messages still stand.
- No TODO stubs that silently return empty values. If something is unimplemented,
  `fatalError("unimplemented: <what>")` so it is loud.
- Do not add features, settings, or abstractions that are not in the current
  milestone's scope. Ask first.
- When a spec item turns out to be wrong or infeasible, say so and propose an
  alternative — do not silently substitute.
- Prefer boring, explicit code. This is a long-lived personal tool, not a demo.
- Performance is a correctness property here, not a polish item. If an approach
  is simpler but allocates a web view eagerly, holds strong delegate references,
  or drives SwiftUI from a timer, reject it and say why. Flag any design choice
  you expect to cost memory or main-thread time when you propose it — before
  writing it, not after.

---

## 12. Open Decisions

Raise these when the relevant milestone starts; do not decide unilaterally.

- ~~GRDB vs Core Data (M1).~~ Resolved: GRDB (ADR 001).
- ~~Whether history is full-text searchable or title/URL only (M3).~~ Resolved:
  title and URL only (ADR 007).
- ~~Archive retention policy for swept ephemeral tabs (M3).~~ Resolved: last
  100, no time limit, blobs dropped on archive.
- ~~Whether extension contexts are per-Space or global (M7).~~ Resolved:
  per-Space, one `WKWebExtensionController` per Space (ADR 011).
