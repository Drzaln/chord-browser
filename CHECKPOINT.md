# Checkpoint

Living handoff document. **Update it in the same commit as the work it
describes** — a stale checkpoint is worse than none, because the next agent will
believe it.

Read [BROWSER_SPEC.md](BROWSER_SPEC.md) first. It is the contract; this file is
only the current position within it.

---

## Status

| | |
|---|---|
| **Completed** | M1 Browse, M2 Spaces, M3 Command bar, M4 Session restore + downloads, M5 Split view + Little Arc |
| **In progress** | M6 Polish — collapsible sidebar done |
| **Next** | M6's remainder: swipe Space switching, cross-section drag, find-in-page, print, PDF |
| **Branch** | `main` — single branch, linear history, one commit per milestone |
| **Tests** | 188 passing (170 unit + 18 end-to-end) |
| **Schema** | v3 (`v1_initial`, `v2_add_spaces`, `v3_history_and_archive`) |
| **Toolchain** | Swift 6.3.3, Xcode 26.6, macOS 26.5 host, target floor 15.4 |

**The §6.1 performance gate passes** as of 2026-07-23, re-run for M5 with split
view and Little Arc in the fixture. App 58 MB, total 498 MB, idle 0.083%
visible / 0.006% occluded — every budget clear by a wide margin, and no leak
over 30 minutes. Numbers and method in [SMOKE.md](SMOKE.md); the runner is
`scripts/soak.sh` (`seed` then `run`). Two gaps remain, neither blocking: no
Instruments pass, and sidebar scroll is still unmeasured. See Carried debt.

## Build and verify

```bash
./scripts/prepush.sh
```

Builds all packages, runs all tests, builds the app. Warnings are errors.
Manual checks live in [SMOKE.md](SMOKE.md).

The app is sandboxed; runtime data lives at
`~/Library/Containers/com.rizal.browser/Data/Library/Application Support/Browser/`.
Inspecting `browser.sqlite` with `sqlite3` is the quickest way to confirm real
behaviour after driving the UI.

**Never `cp` that database to back it up, and never restore one next to a
stale `-wal`.** GRDB runs in WAL mode: recent commits live in
`browser.sqlite-wal`, so a copy of the main file alone is stale, and dropping
it back beside a *newer* WAL replays that WAL over an older database. That
corrupted the store on 2026-07-23 and took a `sqlite3 .recover` pass to undo
(history and archive survived; the tab list did not). Use `.backup` to snapshot
and delete `-wal`/`-shm` when restoring — `scripts/soak.sh` does both now.

### Driving the running app

Accessibility automation **is** granted on this machine, and it is how the
command bar was verified. This works:

```bash
osascript -e 'tell application "System Events" to tell process "Browser" to set frontmost to true'
osascript -e 'tell application "System Events" to keystroke "t" using command down'
osascript -e 'tell application "System Events" to tell process "Browser" to return count of windows'
```

Window count is the cheapest signal: 1 = main window only, 2 = command bar open.
`value of value of attribute "AXFocusedUIElement"` reads the focused field.
**Screen recording is granted** (confirmed 2026-07-23) — `screencapture -x -o
out.png` works, so you *can* see the app, not merely query it. Earlier
milestones recorded the opposite and it was true then; that is why the command
bar shipped for two milestones with its result list invisible. Take a
screenshot before believing any claim about appearance.

Note that AX returns `missing value` for role, title, and value on the command
bar's SwiftUI hosting view. Element *count* is still a usable signal, but to
read its text you need a screenshot.

## Where things are

```
BrowserApp/              @main, AppDelegate, debug overlay (Cmd+Ctrl+P, DEBUG only)
Packages/Sources/
  BrowserCore/           value types + pure logic (ranking, sweep policy). Foundation only.
  BrowserPersistence/    GRDB, migrations, row types, mappers
  BrowserEngine/         the ONLY package importing WebKit
  BrowserStore/          TabStore (+Spaces/+Sweep/+CommandBar/+Split/+LittleArc/+Restore)
  BrowserUI/             SwiftUI + command bar and Little Arc panels. Never WebKit.
  BrowserTestSupport/    fakes, TabBuilder, TestHTTPServer
Packages/Tests/
  Browser*Tests/         unit tests per package
  BrowserE2ETests/       full stack: real engine + real SQLite + real HTTP
docs/adr/                why the non-obvious calls were made
```

## Invariants — do not break these

1. **No `WK*` type in `BrowserEngine`'s public interface.** UI sees web content
   only as `AnyWebSurface`. Resist adding a JS-eval method to observe pages —
   the e2e tests report through the page title instead, precisely to avoid it.
2. **`BrowserCore` imports Foundation and nothing else.** The interesting logic
   (fuzzy ranking, sweep eligibility) lives there as pure functions, which is
   why it is testable without a UI, a clock, or WebKit.
3. **Restore is lazy.** N saved tabs must create 0 web views. Asserted in unit
   *and* e2e tests.
4. **Volatile state (load progress) goes to `PaneRuntime`, never to `tabs`.**
5. **A web view belongs to the Space it was created in.** Resolve the Space from
   the *tab*, never the selection; evict before moving a tab. ADR 006.
6. **Per-view `WKUserContentController`.** `WKWebViewConfiguration.copy()` shares
   it, and a duplicate script-handler name throws and kills the app on the
   second tab. ADR 008.
7. **Keyboard shortcuts live in `BrowserCommands` only.** A view-level
   `.keyboardShortcut` is handled in the window's responder chain and silently
   beats the menu item with the same key. See "Keyboard shortcut hazards".
8. **Never persist `Codable` app models.** Row types + mappers only.
9. **Decoding is defensive.** A corrupt row costs one tab, never a launch.
10. **Migrations are forward-only, named, never edited once shipped**, each with
    a fixture test built from the prior version (`Migrations.v1ForTesting`).
11. **Never invent WebKit API.** Verify against the SDK headers:
    `$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/WebKit.framework/Headers/`
    This is how the missing `isPlayingAudio` was caught before writing against it.

## Keyboard shortcut hazards (learned the hard way in M3)

All three of these cost real debugging time. They are not obvious from the code.

- A SwiftUI **view-level `.keyboardShortcut` beats a menu item** with the same
  key. A leftover `Cmd+T` on the sidebar's New Tab button silently swallowed the
  command bar shortcut and quietly opened tabs instead. Shortcuts belong in
  `BrowserCommands`.
- A focused **`TextField` consumes Return** for its own submit, and **ignores
  Cmd+Return entirely** — `onSubmit`, `onKeyPress`, and a scoped
  `.keyboardShortcut(.return, modifiers: .command)` all fail to see it. Cmd+Enter
  is therefore caught in `CommandBarPanel.performKeyEquivalent`.
- The command bar panel is **built once and reused**, so `onAppear` fires only
  on the first presentation. Reset and focus are driven by `CommandBarSession`'s
  present token. Focus is requested repeatedly for ~200 ms because the panel
  becoming key races the view update; a single request loses that race
  intermittently and yields a bar you cannot type into.

Window tabbing is disabled in `AppDelegate.disableWindowTabbing()` — we have our
own vertical tabs and do not want the system tab bar or its shortcut claims.

**Any panel must size itself from its content, and say so twice.** This has now
bitten in two milestones. Assigning `contentViewController` makes the window
adopt that controller's *fitting* size, and a web surface has no intrinsic
height — Little Arc's panel opened at 105x37 until `setContentSize` was called
*after* the assignment.

**The panel must size itself from its content.** It shipped in M3 with a fixed
`640x60` frame and an `autoresizingMask` on the hosting *view* — which makes the
view follow the window, never the reverse. The result list rendered correctly
and was clipped away entirely; every M3 behavioural check passed because Return
still activated the right row. It is an `NSHostingController` with
`sizingOptions = [.preferredContentSize]` now, and `setFrame` is overridden to
anchor the top edge, because AppKit preserves the bottom-left corner on resize
and the bar would otherwise crawl upward as you type.

## How M5 works

- **Split view is a tab with more panes** (3.2), so no new type and no
  migration: `PaneRow` already carried `position` and `widthFraction` from M1.
- `SplitLayout` in Core owns the width maths, so the invariant that fractions
  sum to 1.0 is provable without a gesture.
- A divider drag must be measured in **`.global`** space and applied to the
  widths snapshotted at drag *start*. The divider moves as it resizes; local
  coordinates and accumulated deltas both make it run away from the cursor.
- **Little Arc's page is an ordinary `Pane` that is in no `Tab`** — invisible to
  the sidebar, the sweep, and persistence. It uses the active Space's data
  store, so a link arrives already logged in. Promotion reads the *current* URL,
  not the one it opened with, then tears the panel's view down: nothing else
  refers to that pane, so it would otherwise outlive the app.
### How drag-to-split works

Both ends of the drag are AppKit and both are ours. That is the whole fix.

- **The source is `TabDragSource`**, an `NSView` overlaid on the sidebar row
  that starts a `beginDraggingSession` with an `NSPasteboardItem`. SwiftUI's
  `onDrag` is what held this up for a milestone: its `NSItemProvider` reaches
  the destination with `com.rizal.browser.tab` advertised on the pasteboard and
  **zero bytes** behind it — `data(forType:)` returns empty `Data`, not nil, via
  both the pasteboard and `pasteboardItems`. A lazy `registerDataRepresentation`
  and an eager `NSItemProvider(item:typeIdentifier:)` both do it. Do not go back
  to `onDrag` here.
- **The destination is `TabDropTarget`**, mounted over a pane only while a drag
  is in flight. `WKWebView` registers for dragged types itself and AppKit picks
  the *deepest* registered view under the cursor, so a SwiftUI `onDrop` on the
  hosting view always loses to the page. A permanent AppKit layer would win the
  drop but eat every ordinary click.
- **The destination must return an operation the source offers.** `onDrag`
  advertised `.copy` while 4.5 wants a move, and returning `.move` against it
  made AppKit refuse the drop outright — the pane highlighted on hover and
  release did nothing. Our source offers `.move` within the app and nothing
  outside it.
- **`TabDragPayload` is the one place the byte format lives**, because the
  destination cannot tell "the source wrote something else" from "the source
  wrote nothing" — both look like a drop that did nothing.
- The source view takes the row's click too (it sits above the row), and stops
  short of the close button so that stays clickable. Its "was this a drag?" flag
  is cleared by the next `mouseDown` and never when the session ends: clearing
  it in `draggingSession(_:endedAt:operation:)` let a mouse-up arriving
  afterwards read as a plain click, so ending *any* drag also selected the row
  that had just been dragged.
- Tests cover the payload only (`BrowserUITests`). **No test covers the drag**,
  and the one that would have mattered cannot be written: the empty-payload bug
  only happens inside a live drag session. It was found, and the fix verified,
  by driving the real app — see SMOKE.md.

- The app is a `Window`, **not a `WindowGroup`** (1). A group spawns a second
  window when a URL is handed to the app, whose `RootView` then calls
  `store.restore()` again on the same store — which failed its load and replaced
  a working session with an empty one. `restore()` is now guarded to run once.

## How the collapsible sidebar works

- **The lane and the sidebar are different widths.** `RootView` reserves
  `laneWidth` in the layout and draws the sidebar over it in a `ZStack`. A
  hover-expanded sidebar therefore overhangs the page instead of pushing it —
  4.1 requires that hovering not shift web content, and shifting it would
  relayout every web view for the length of a hover.
- **`showsRail` is not `store.isSidebarCollapsed`.** A collapsed sidebar under
  the pointer is expanded; only the two together make the icons-only rail.
- **The traffic lights are hidden while the rail shows** (`TrafficLights`).
  AppKit puts them at a fixed offset from the window's top-left regardless of
  what is underneath, so in a 48-point rail the zoom button lands on the web
  content. They return on any expand, including a hover.
- **Collapse-on-exit is delayed and cancellable** (`Motion.sidebarCollapseDelay`).
  Zero delay makes the sidebar snap shut while the pointer travels from a row
  to the page.
- The state is a window preference in `UserDefaults`, not a schema column: it
  is not user data and has no business carrying a migration.
- `SpaceSwitcher` swaps `HStackLayout` for `VStackLayout` through `AnyLayout`
  rather than branching to two copies of the content, so the icons keep their
  identity and animate into place instead of being torn down.

## Next steps, in order

1. **M6's remainder**: swipe-driven Space switching, cross-section
   drag-and-drop, animation tuning, find-in-page, print, PDF viewing.

M6's cross-section drag-and-drop should start from `TabDragSource` — the sidebar
row is already an AppKit drag source, and reordering within the sidebar needs a
destination beside it, not a second mechanism. Do not reach for SwiftUI's
`onDrag`/`onMove` for it; see "How drag-to-split works".

Not blocking, and worth doing whenever: the Instruments pass §6.7 wants
(Allocations/Leaks, never run), and sidebar-scroll fps now that screen recording
is available. `BrowserUITests` now exists (it did not, which is why panel sizing
broke twice with a green suite), but it holds only the drag payload — panel
sizing is still uncovered.

## Carried debt

- ~~Drag a tab into a split does not work yet.~~ **Done 2026-07-23**, described
  under "How drag-to-split works" below.
- **`cliclick` is installed** and is how the divider drag was finally verified.
  Use `dm:` (not `m:`) between `dd:` and `du:` — `m:` sends *mouseMoved*, which
  a SwiftUI `DragGesture` tolerates but an AppKit drag session ignores.

- **Double-click on the top strip no longer zooms the window.** Introduced by
  the `.ignoresSafeArea(.container, edges: .top)` that removed the dead band
  above the web content: the card now covers the region AppKit would have
  handled the double-click in. Dragging still works. The fix is a thin
  drag/zoom region over the top inset rather than reverting the layout —
  deferred deliberately, not forgotten.

- ~~No 30-minute soak has been run, for any milestone.~~ **Cleared 2026-07-23.**
  Soak run and every §6.1 budget measured; all pass, with the numbers and their
  caveats in [SMOKE.md](SMOKE.md). No leak: app footprint 70 MB → 62 MB over 30
  minutes, total flat at ~720 MB. Headroom is large — the app process is using
  under half its 150 MB target with 12 live views.
- **Instruments passes (§6.7) are still not done** for M1/M3. The numbers above
  come from `footprint`, CPU-time deltas, `sample`, and signposts, which is
  enough to clear the §8 gate but does not give first-*painted*-frame timings or
  an Allocations/Leaks trace.
- **Sidebar scroll (120 fps) is still unmeasured**, but no longer known to be
  unmeasurable: screen recording is granted now, so a capture-based approach is
  worth trying before declaring it impossible.
- ~~Nobody has logged into two real Google accounts by hand.~~ **Done
  2026-07-23** — verified by hand against real Google auth, M2's done-when.
- ~~The command bar's *appearance* is unverified.~~ **Verified 2026-07-23** by
  screenshot, which is how the clipped result list below was found. A full
  visual sweep followed (sidebar, favicon fallback, progress bar, Space
  gradients, command bar navigation) — results in [SMOKE.md](SMOKE.md).
- **`FuzzyMatch` accepts any subsequence**, so `goo` matches "WKDownloadDelegate
  | Apple Developer Documentation". Weak matches rank last and are noise rather
  than wrong answers, but the bar fills with rows a user would not call
  matches. Wants a quality floor, not just a score. Found in the visual sweep.
- **History records challenge pages** — a Cloudflare "Just a moment…" entry is
  in there. `recordVisit` skips blank and error pages, but not interstitials.

## Deviations from the spec

Each has an ADR; the spec text was updated in the same commit.

- `WKProcessPool` unused — Apple deprecated it to a no-op (ADR 004)
- `BrowserStore` is a package the §3.5 list omitted (ADR 005)
- Audio playback detected by user script, not the SPI everyone else uses (ADR 008)
- `Cmd+T` opens the command bar per §4.4; plain new tab moved to `Cmd+N`
- `Cmd+T` opens results in a *new* tab, `Cmd+L` navigates the *current* one.
  §4.4 originally had Return always navigate the current tab, which meant
  `Cmd+T` replaced the tab you were on — the one thing nobody expects it to do.
  Spec text updated in the same commit.

## Open decisions (BROWSER_SPEC §12)

- Extension contexts per-Space or global (M7)

Resolved: GRDB over Core Data (ADR 001); history is title/URL only (ADR 007);
archive keeps the last 100, no time limit.

## How M4 works

- **Capture** happens on tab deactivation (`TabStore.select`), on occlusion, and
  on quit. Eviction still captures too. A force-quit loses only what changed
  since the last switch — that is the reason capture is not left to quit alone.
- **Quit is awaited.** `applicationShouldTerminate` returns `.terminateLater` and
  replies once the writes land. `applicationWillTerminate` cannot do this: it
  cannot wait, and a detached task never runs before the process dies.
- **Resolution is lazy.** A restored pane starts with no blob; it is read the
  first time the pane is shown. `surface(for:)` returns nil while that read is in
  flight, which is why the content view renders its card and nothing else for a
  frame. Building the view first would load the bare URL and then have to throw
  it away.
- **Pruning** happens after every save, because `paneInteractionState` has no
  foreign key to `pane` and nothing else would reclaim a closed tab's blob.
- ~~Known latent bug, will bite in M5.~~ **Fixed in M5.** `surface(for:)` gated
  on `tab.focusedPaneID` while capture and resolution iterated every pane —
  identical with one pane per tab, wrong the moment split view renders a second.
  Now `surface(for:in:)` per pane. Worth knowing how it was caught: the *e2e*
  regression test for it **passed against the buggy code**, because it polled
  until resolution finished and both panes always resolved together. Only a
  unit test that forces the two panes to disagree
  (`pendingPaneWithholdsItsOwnSurface`) actually fails against the old gate.
  Verify a regression test fails before trusting it.
- Brand-new tabs are marked resolved at creation — nothing is stored for them, so
  a disk read would only cost a frame of withheld surface.
### Downloads — verified against the SDK headers, then against the real app
  - Required: `download(_:decideDestinationUsing:suggestedFilename:completionHandler:)`.
    Hand back a file URL that does **not** exist, in a directory that does.
  - Optional: `downloadDidFinish(_:)`,
    `download(_:didFailWithError:resumeData:)`, redirect and auth-challenge
    callbacks.
  - `WKDownload` conforms to `NSProgressReporting` — progress UI reads
    `download.progress`, it does not count bytes by hand.
  - Downloads arrive via `WKNavigationDelegate`'s
    `webView(_:navigationAction:didBecomeDownload:)` /
    `webView(_:navigationResponse:didBecomeDownload:)` after returning the
    `.download` policy, or from `startDownloadUsingRequest`. **The delegate must
    be set inside those callbacks** or progress is never reported.
  - `decidePlaceholderPolicy` / `didReceivePlaceholderURL` / `didReceiveFinalURL`
    are **iOS and visionOS only — they do not exist on macOS.** There is no
    placeholder-file path available to us.
- **The sandbox now grants `com.apple.security.files.downloads.read-write`**, so
  downloads go straight to `~/Downloads` with no save panel. Chosen deliberately
  over an `NSSavePanel` per download, which the existing user-selected
  entitlement would have covered without widening the sandbox.
- **`swift test` runs unsandboxed, so the e2e download test cannot prove the
  entitlement works.** That was verified by hand against the real app instead:
  a 200 KB file downloaded to `~/Downloads` byte-for-byte identical to source.
  Re-verify by hand after touching entitlements; no automated test covers it.
- The archive deliberately drops `interactionState` (§4.3, ADR 007); restoring an
  archived tab reloads. Intended, not an oversight to "fix".
- `E2EHarness.relaunch()` makes a second store over the same directory, which is
  how "quit and relaunch" is tested. Use `flushSaveAndWait()` before relaunching
  — plain `flushSave()` is fire-and-forget and the write will not have landed.
