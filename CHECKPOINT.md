# Checkpoint

Living handoff document. **Update it in the same commit as the work it
describes** — a stale checkpoint is worse than none, because the next agent will
believe it.

Read [BROWSER_SPEC.md](BROWSER_SPEC.md) first. It is the contract; this file is
only the current position within it.

---

## Status

|                 |                                                                                                                 |
| --------------- | --------------------------------------------------------------------------------------------------------------- |
| **Completed**   | M1 Browse, M2 Spaces, M3 Command bar, M4 Session restore + downloads, M5 Split view + Little Arc, M6 Polish     |
| **In progress** | **M7 Extensions** — 7.1, 7.2, **7.3a** done (seam + per-Space wiring + install helper + load path with MV3 enforcement), behind `FeatureFlags.extensionsEnabled` (default off) |
| **Next**        | M7 phase **7.3b** — the `WKWebExtensionTab`/`WKWebExtensionWindow` model (needs `TabStore` injection + live verification with a real extension) |
| **Branch**      | `main` — single branch, linear history, one commit per milestone                                                |
| **Tests**       | 248 passing (229 unit + 19 end-to-end)                                                                           |
| **Schema**      | v3 (`v1_initial`, `v2_add_spaces`, `v3_history_and_archive`)                                                    |
| **Toolchain**   | Swift 6.3.3, Xcode 26.6, macOS 26.5 host, target floor 15.4 (SPM platform raised from .v15 to 15.4 in M7)       |

**The §6.1 performance gate passes** — re-run for M6 on 2026-07-24 with the
swipe scroll monitor, the sidebar drop layer, and the find bar's cancellable
task all in play. App process flat at 40–50 MB (43 MB at end), total settled at
~410 MB, no leak over 30 minutes. Every budget clear by a wide margin. Numbers
and method in [SMOKE.md](SMOKE.md); the runner is `scripts/soak.sh` (`seed` then
`run`, `restore` to put the real session back). Two gaps remain, neither
blocking: no Instruments pass, and sidebar scroll is still unmeasured. See
Carried debt.

## Kickoff prompt for the next session

Paste this whole block. It is deliberately blunt about the traps, because every
one of them has already cost a session here.

```
Read BROWSER_SPEC.md and CHECKPOINT.md in full before writing any code.

M1-M5 are done. M6 (Polish) is partly done: the sidebar hides and reveals from
the screen edge, favourites are a per-Space pinned grid, find-in-page works, and
New Tab / Split Tab both open the command bar. Single `main` branch, 201 tests
passing, `./scripts/prepush.sh` green.

Start with the ordered list under "Next steps" in CHECKPOINT.md. In short:
finish M6 — swipe-driven Space switching with swipe animation (that works really good!), cross-section drag-and-drop, an
animation tuning pass, print, and PDF viewing — then re-run the soak and stop.

Follow Section 11 strictly. In particular:

**Never invent WebKit API.** Check the SDK headers under
$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/WebKit.framework/Headers/
rather than assuming a symbol or a signature, and tell me when something does
not exist instead of guessing. That is how M4 learned `decidePlaceholderPolicy`
is iOS-only, and how M6 learned `WKFindResult` reports only `matchFound` — so a
"3 of 12" find counter is not buildable and the find bar does not pretend.

**Verify UI work by driving the real app, not by reasoning about it.** Screen
recording and accessibility are granted and `cliclick` is installed:
`screencapture -x -o out.png`, `osascript` for keys, `cliclick` for the pointer.
Use `dm:` (not `m:`) between `dd:` and `du:`. Get a window's real frame from
`osascript ... get position of window 1` rather than estimating it off a
screenshot — M6 aimed at a 6-point edge strip from a guess and missed it twice.
Reading one pixel (`screencapture -x -R<x>,<y>,4,4`) is a cheap way to assert
"is the sidebar showing" without spending a screenshot.

**Before trusting a regression test, verify it fails against the bug.** Two
tests in this repo passed against the very bug they claimed to cover — one
because a redundant condition masked the real guard, one because a synchronous
fake made the race impossible to stage. Break the fix, watch the test go red,
put it back.

**`swift test` runs UNSANDBOXED**, so it cannot verify anything
entitlement-dependent; that needs a manual check against the real app.

Update CHECKPOINT.md in the same commit as the work it describes.
```

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
it back beside a _newer_ WAL replays that WAL over an older database. That
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
out.png` works, so you _can_ see the app, not merely query it. Earlier
milestones recorded the opposite and it was true then; that is why the command
bar shipped for two milestones with its result list invisible. Take a
screenshot before believing any claim about appearance.

Note that AX returns `missing value` for role, title, and value on the command
bar's SwiftUI hosting view. Element _count_ is still a usable signal, but to
read its text you need a screenshot.

## Where things are

```
BrowserApp/              @main, AppDelegate, debug overlay (Cmd+Ctrl+P, DEBUG only)
Packages/Sources/
  BrowserCore/           value types + pure logic (ranking, sweep policy). Foundation only.
  BrowserPersistence/    GRDB, migrations, row types, mappers
  BrowserEngine/         the ONLY package importing WebKit
  BrowserStore/          TabStore (+Spaces/+Sweep/+CommandBar/+Split/+LittleArc/+Restore/+Find)
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
   _and_ e2e tests.
4. **Volatile state (load progress) goes to `PaneRuntime`, never to `tabs`.**
5. **A web view belongs to the Space it was created in.** Resolve the Space from
   the _tab_, never the selection; evict before moving a tab. ADR 006.
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
adopt that controller's _fitting_ size, and a web surface has no intrinsic
height — Little Arc's panel opened at 105x37 until `setContentSize` was called
_after_ the assignment.

**The panel must size itself from its content.** It shipped in M3 with a fixed
`640x60` frame and an `autoresizingMask` on the hosting _view_ — which makes the
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
  widths snapshotted at drag _start_. The divider moves as it resizes; local
  coordinates and accumulated deltas both make it run away from the cursor.
- **Little Arc's page is an ordinary `Pane` that is in no `Tab`** — invisible to
  the sidebar, the sweep, and persistence. It uses the active Space's data
  store, so a link arrives already logged in. Promotion reads the _current_ URL,
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
  the _deepest_ registered view under the cursor, so a SwiftUI `onDrop` on the
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
  afterwards read as a plain click, so ending _any_ drag also selected the row
  that had just been dragged.
- Tests cover the payload only (`BrowserUITests`). **No test covers the drag**,
  and the one that would have mattered cannot be written: the empty-payload bug
  only happens inside a live drag session. It was found, and the fix verified,
  by driving the real app — see SMOKE.md.

- The app is a `Window`, **not a `WindowGroup`** (1). A group spawns a second
  window when a URL is handed to the app, whose `RootView` then calls
  `store.restore()` again on the same store — which failed its load and replaced
  a working session with an empty one. `restore()` is now guarded to run once.

## How M6 works (so far)

### The sidebar: hide and reveal

Arc's model: collapsed means **gone**, not narrowed, and the pointer reaching
the window's left edge brings it back over the page.

- **The lane and the sidebar are different widths.** `RootView` reserves
  `laneWidth` — zero when collapsed — and draws the sidebar over it in a
  `ZStack`. A revealed sidebar overhangs the page instead of pushing it: 4.1
  requires that revealing not shift web content, and shifting it would relayout
  every web view for as long as the pointer sat there.
- **The edge reveal is an `NSTrackingArea`, and that detail matters.** With the
  sidebar fully hidden there is no view left to hover, and the strip that
  replaces it lies over the web view. Two approaches failed first: a SwiftUI
  `onHover` overlay swallows clicks meant for the page (and
  `allowsHitTesting(false)` kills the hover too — the M5 drop-target trap), and
  a `mouseMoved` local monitor never fired. A tracking area reports enter and
  exit _regardless of hit testing_, so `hitTest` returns nil and clicks pass
  straight through.
- **The traffic lights are hidden while the sidebar is** (`TrafficLights`).
  AppKit puts them at a fixed offset from the window's top-left regardless of
  what is underneath, so with no sidebar they land on the page. **Except in
  fullscreen:** hiding them there left no way out but the keyboard, so
  `RootView.shouldHideTrafficLights` is `isHidden && !isFullscreen` and the
  fullscreen enter/exit notifications re-evaluate it. In fullscreen AppKit shows
  the lights in the auto-revealing top overlay, not over the page, so the
  land-on-content reason does not apply.
- **Hide-on-exit is delayed and cancellable** (`Motion.sidebarCollapseDelay`).
  Zero delay makes the sidebar snap shut while the pointer travels toward a row
  near its edge.
- The revealed sidebar is a floating card — rounded, shadowed, inset — and the
  in-lane one is flush. That is Arc, and it is what makes the revealed state
  read as _over_ the content rather than part of it.
- The collapsed state is a window preference in `UserDefaults`, not a schema
  column: it is not user data and has no business carrying a migration.

### Favourites (pinned tabs)

- `TabPlacement.pinned` and `setPinned` existed from M1, in the model _and_ the
  schema. The sidebar simply never separated them from the ephemeral tabs, so
  there is no new state here and no migration — only §4.1's section, finally
  rendered, as `PinnedGrid`.
- **Per-Space comes for free** because `pinnedTabs` filters `visibleTabs`,
  which is already scoped to the active Space. That is worth a test rather than
  a comment: a regression leaks one Space's favourites into another.

### Find-in-page

- **`WKFindResult` reports `matchFound` and nothing else** — no total, no index
  of the current match. "3 of 12" is not buildable on the public API, so the bar
  says found or not found. Do not add a counter by injecting a DOM-walking
  script; that is a page-rewriting mechanism this app has no other use for.
- **Clearing the highlight goes through `evaluateJavaScript`**, which is not the
  preferred route and is deliberate. There is no modern equivalent:
  `deselectAll` belongs to the legacy `WebView`, and `WKWebView` has no
  stop-finding call. Verified against the headers, not assumed.
- It searches the **focused pane**, not the tab. In a split, Cmd+F means the
  pane you are reading; searching all of them scrolls panes you are not.
- An emptied field reports _nothing_ rather than "not found", or the bar flashes
  red on every backspace as a query is deleted.

### Swipe-driven Space switching (4.2)

- **Raw scroll-phase `NSEvent`, not a gesture recogniser** — a recogniser
  reports a swipe after the fact and cannot drive progress continuously, which
  is the whole feel. `SpaceSwipeMonitor` installs a _local_ event monitor
  (`addLocalMonitorForEvents(matching: .scrollWheel)`) so it sees the event
  before any view dispatch and can consume a swipe the `WKWebView` would
  otherwise scroll. It engages only when a gesture _begins_ with
  `abs(scrollingDeltaX) > abs(scrollingDeltaY)` **and** carries a real trackpad
  `phase` — a mouse wheel has no phase and a vertical scroll reaches the page.
- **Scoped to the sidebar, so it never fights back/forward.** The gesture only
  engages when the swipe begins over the sidebar (`event.locationInWindow.x <=
engageMaxX`, where `RootView` keeps `engageMaxX` at the sidebar's right edge —
  zero while the sidebar is hidden — and passes the main window so a floating
  panel is ignored). A swipe over the web content falls straight through to
  `WKWebView`'s own back/forward navigation gesture
  (`allowsBackForwardNavigationGestures`, already on). Without this the two
  same-shaped gestures collided and a two-finger swipe over a page switched Space
  instead of navigating.
- **The maths is pure and lives in Core** (`SpaceSwipe`): full-swipe distance,
  commit threshold, rubber-band curve, and the stop-for-stop gradient blend
  (`ColorHex.lerp`). Tested without a trackpad.
- **The gradient blend is continuous across the commit.** On release past the
  threshold the monitor springs `spaceSwipeProgress` to `±1` and only _then_
  calls `commitSpaceSwipe` — `blend(old, new, 1.0)` equals the neighbour's stops
  exactly, and resetting to 0 over the now-active Space shows the same pixels,
  so there is no jump. Below the threshold it springs back to 0.
- **The idle path does not blend.** `SidebarView` uses the cached
  `SpaceTheme.gradient(for:)` while `spaceSwipeProgress == 0` and only builds the
  uncached blended gradient during an active swipe, so an idle sidebar is not
  rebuilding a gradient every frame (6.4).
- **Not verified by driving the real app.** A two-finger phased swipe cannot be
  synthesized by `cliclick`/`osascript` — they cannot emit `.began`/`.changed`/
  `.ended` scroll `NSEvent`s. The blend/commit/rubber-band logic is unit-tested,
  and the _rendering_ path is shared with discrete `Cmd+1…9` switching, which was
  screenshot-verified (blue Space → red Space). The continuous gesture itself
  still wants a hands-on trackpad check.

### Cross-section drag-and-drop (4.1)

- **Destinations beside the source, one mechanism.** The row is already a
  `TabDragSource` (AppKit, real `NSPasteboardItem` bytes). The sidebar now has
  `SidebarDropTarget` — a generic AppKit drop view reading the same `.browserTab`
  payload — laid over three regions, so nothing here reaches for SwiftUI
  `onDrop`/`onMove` (see "How drag-to-split works").
- **`reorderTab(_:toPinned:at:)` in Core-adjacent Store logic** does both jobs at
  once: `pinned == the tab's current section` is a reorder, a change of section
  pins/unpins it as it moves. It renumbers only the _destination_ section densely
  and leaves the source's orders monotonic-with-a-gap, which `visibleTabs` sorts
  fine. Unit-tested (`ReorderTests`), including per-Space isolation.
- **Three drop regions**, all mounted only while `draggingTabID != nil` so they
  never eat an ordinary click: the ephemeral list (reorder / accept an unpin,
  with a cursor-Y insertion indicator), the favourites grid (pins, appends), and
  each Space button (moves Spaces via the existing `moveTab(_:toSpace:)`). When a
  Space has no favourites yet, a dashed "Pin to Favourites" zone appears during a
  drag so the first one can be made by dragging.
- **Pinned tiles are drag sources too** now, so a favourite can be dragged out to
  unpin, onto a Space, or reordered.
- **Verified live with `cliclick`** (`dd`/`dm`/`du`, as the divider drag was):
  drag-to-pin moved a tab from the list into the grid (list 4→3), and
  drag-onto-Space-2 moved a tab out of the active Space (list 3→2). Reorder
  _within_ a section was not eyeballed — the fixture tabs share a title, so it is
  invisible on screen — but it is the same drop path and is unit-tested.
- **Simplification:** a drop onto the grid appends rather than landing on the
  aimed-at cell; the grid has no obvious linear slot and the end is predictable.

### Print and PDF

- **Print goes through the engine so no AppKit-print type leaks.** The store
  calls `engine.printPane(paneID:)` on the focused pane (like find, 4.1); the
  `NSPrintOperation` is built and run entirely inside `WebKitEngine`.
- **It must be `runModal(for: window…)`, not `runOperation()`.** WebKit builds
  its printing view lazily against a window context; the synchronous
  `runOperation()` runs before that exists and AppKit puts up "This application
  does not support printing." Also a pane with no live view is skipped — there is
  nothing to render.
- **The sandbox needs `com.apple.security.print`.** Without it the print system
  is refused and you get the _same_ "does not support printing" alert even with
  the correct call — which is the trap, since it looks identical to the code bug.
  Added to `Browser.entitlements`. `swift test` runs unsandboxed and cannot catch
  this; it was found and the fix confirmed by driving the real app (the print
  panel with a live page preview now appears). Re-verify by hand after touching
  entitlements — no automated test covers it, exactly as with downloads.
- **PDF viewing is free.** `WKWebView` has a built-in PDF renderer, so
  `canShowMIMEType` is true for `application/pdf` and the navigation policy
  already returns `.allow` — no download, no code. Verified live: a PDF URL
  rendered inline, and the tab even picked up the document's title and favicon.
  Nothing was built for it; the only risk is a future WebKit that drops the
  built-in viewer, at which point the response policy would start downloading
  PDFs and this note is where to look.

### Animation and Reduce Motion pass (5)

- **Every animation entry point already routes through one helper**,
  `Motion.respectingReduceMotion`, or honours the setting explicitly: the tab and
  Space-switch springs, the sidebar collapse, the progress bar, the swipe
  release, and Little Arc's scale-in (which skips straight to `alphaValue = 1`
  under Reduce Motion). This was an audit as much as a change — the discipline was
  already there.
- **The sidebar reveal now _fades_ under Reduce Motion** rather than sliding.
  `respectingReduceMotion` only speeds the driving animation to near-instant; the
  `.move(edge: .leading)` transition still travelled. Swapping it for `.opacity`
  when `reduceMotion` is set drops the travel, which is the actual point of the
  setting. One line in `RootView`.
- **Not toggled live.** Flipping Reduce Motion means driving System Settings'
  accessibility pane, which changes a system-wide setting — not done. The routing
  is auditable in source (all through the single helper) and the helper itself is
  trivial and unit-testable; a hands-on toggle is the one remaining manual check.

### Custom Space icon and colour (post-M6 addition)

- **Emoji or SF Symbol, no schema change.** `iconSymbol` and `gradient` were
  already free-form persisted columns, so a custom emoji lives in `iconSymbol`
  and a custom colour in `gradient` with no migration. `Space.isEmojiIcon` picks
  the render path: an SF Symbol name is always ASCII, so any non-ASCII scalar
  means draw it as `Text`, not `Image(systemName:)`.
- **`SpaceEditor`** is a sheet from the Space context menu ("Edit Space…") with a
  name field, an icon field (free entry + a quick-pick emoji row), and a
  `ColorPicker`. The picked colour becomes a two-stop gradient (accent + a darker
  sibling) so the sidebar stays a gradient rather than a flat fill. Colour↔hex
  conversion is AppKit-side in the editor, kept out of Core.
- **Store:** `setSpaceAppearance(_:icon:gradient:)` persists both; an empty icon
  is ignored rather than blanking the Space, and an empty gradient falls back to
  the default. `SpaceTheme`'s cache invalidates on a stops change by itself.
  Covered by `SpaceTests`; the emoji render and edit flow were verified live.
- **The editor sheet is presented from `RootView`, not the sidebar.** The
  trigger (`store.editingSpaceID`, ephemeral UI state) is in the store so the
  `.sheet` can live on `RootView`. Presenting it from `SpaceSwitcher` — inside
  `SidebarView` — meant the sheet vanished the moment the sidebar collapsed or
  auto-hid, since the sidebar is pulled out of the view hierarchy then. Reported
  by the user (edit modal gone in collapsed mode); verified live: opened from a
  revealed sidebar, the modal stays centred on the window.
- **The emoji picker is the native macOS Character Viewer**, not a hardcoded
  preset list: the editor's emoji button focuses the icon field and calls
  `NSApp.orderFrontCharacterPalette(_:)`, whose selection inserts into the first
  responder. An `onChange` keeps the field to a single glyph (it only fires for a
  non-ASCII value, so an SF Symbol name is left intact). Verified live — the
  Character Viewer opened and picking 😎 replaced the icon.
- **The Space colour also tints the window border** — the inset frame around the
  content card — not just the sidebar (`RootView.spaceBorderTint`, following the
  swipe blend). It **must** be `.background { spaceBorderTint.ignoresSafeArea() }`:
  without `ignoresSafeArea` the tint stops at the titlebar safe-area line and the
  card's _top_ inset shows raw window chrome, so every edge but the top is
  coloured. Found and fixed by driving the app — the top strip was visibly
  untinted until the tint was told to bleed to the top edge. Verified live: the
  border turns blue for one Space and green for another, top edge included.

### UI polish (post-M6, 2026-07-24)

A batch of small UI improvements. Not manually re-driven by the agent (the user
tests these by hand); they build and the unit suite is green.

- **Space colour tints the tab highlights and address button.** `SidebarView`
  passes `SpaceTheme.accent(for:)` down as a `tint`; `TabRowView` and the
  `PinnedGrid` tiles fill their selected/hover states with `tint.opacity(...)`
  instead of the system `.selection`, and the address button uses the same tint.
  So a selected tab in a green Space reads green, not system blue (items 1 & 4).
- **The sidebar address field is now a button, not a text field.** Clicking it
  opens the command bar in `.currentTab` mode pre-filled with the current URL and
  the text selected — i.e. exactly Cmd+L (item 3). The `openCommandBar` closure
  grew a `String?` prefill argument (threaded App→Root→Sidebar→NavigationBar), and
  `CommandBarSession.initialQuery` carries it; `CommandBarView.reset()` seeds the
  field and `selectAll`s it via the field editor. The button shows the host, not
  the full URL.
- **The command bar dismisses on losing focus.** `CommandBarPanel` observes its
  own `didResignKeyNotification` and orders out — clicking the window behind it
  now closes it, which `hidesOnDeactivate` alone did not do (item 2).
- **The floating sidebar aligns with the traffic lights.** Its card is inset on
  three sides but no longer the top, so the collapse button sits on the same line
  as the lights instead of 8 pt below (item 5).

### The User-Agent

`WKWebView`'s default UA stops at `(KHTML, like Gecko)` — no `Version/` and no
`Safari/` token, because both come from `applicationNameForUserAgent`, which is
unset by default. It is set now (`WebKitEngine.safariUserAgentSuffix`) and
asserted end-to-end, since no unit test sees a real request.

Two things worth knowing:

- **The hard-coded version will go stale.** WebKit exposes no API for Safari's
  version and the sandbox blocks reading its Info.plist. A stale-but-plausible
  version degrades far better than no token at all.
- **This is not the Chrome spoofing §9.6 warns against.** We are WebKit at the
  same version Safari ships; saying so is accurate. Per-domain overrides remain
  the answer for sites that demand Chrome specifically.
- `TestHTTPServer` records request headers per path. Per _path_ because a page
  load is followed by a favicon fetch, and that one comes from `URLSession`
  with CFNetwork's own UA — "the last request" answers about the wrong one.

## How M7 works (so far)

### Phase 7.1 — seam + package + per-Space controller wiring (2026-07-24)

- **Extensions are per-Space** (ADR 011, resolving §12). One
  `WKWebExtensionController` per Space, its configuration keyed by the Space's
  `dataStoreID` (`WKWebExtensionController.Configuration(identifier:)`, verified
  in the SDK headers) and its `defaultWebsiteDataStore` set to the same
  identifier — the storage isolation lives on the controller's config, so
  per-Space *contexts* on a shared controller would not isolate. A private Space
  gets `.nonPersistent()`.
- **The engine layer is the WebKit boundary now, not just `BrowserEngine`.**
  §7.1 was amended: the extension host is a *second* WebKit importer,
  `BrowserExtensions` (imports Core + Engine), rather than bloating the engine
  with an unrelated job. The two engine-layer packages share `WK*` types with
  each other; nothing WebKit-shaped crosses into Store or UI.
- **The seam is the `AnyWebSurface` trick.** `BrowserEngine` declares
  `ExtensionControllerHandle` (opaque; its `WKWebExtensionController` is
  *internal* to the engine) and a WebKit-free `ExtensionControllerProviding`
  protocol. `WebKitEngine.makeWebView` sets `config.webExtensionController =
  handle.controller` when the provider has one for the Space, unwrapping on its
  own side. `WebKitExtensionHost` (in `BrowserExtensions`) builds the
  controllers and conforms to the provider.
- **`AppEnvironment` wires it without importing WebKit** — provider and host are
  WebKit-free in their public surface. `BrowserStore` gained a dependency on
  `BrowserExtensions`; dependencies still flow downward. The host is retained by
  `AppEnvironment` (the engine holds the provider `weak`).
- **Behind a flag** (§7.4): new `FeatureFlags` in Core, `extensionsEnabled`
  default off. With it off `AppEnvironment` builds no host and attaches no
  controller, so the shipping browser is exactly what it was before M7. The flag
  is deleted when M7 ships.
- **SPM platform floor raised `.v15` → `15.4`** to match the documented hard
  floor (§2/§7.3) so the extension API is available without scattering
  `if #available`. The app target was already 15.4.
- **Tests** (`BrowserExtensionsTests/PerSpaceControllerTests`, 6): per-Space
  controller identity and isolation, idempotent `prepare`, nil handle before
  `prepare`, persistent-vs-private configuration. The isolation test was
  confirmed to go red against a deliberately shared-controller bug, then
  restored (per the "verify a regression test fails" rule).
- **Not yet done in 7.1** (by design): no `.crx` unpack, no
  `WKWebExtensionContext` load, no tab/window model. Those are 7.2–7.5.
- **Not verified against the real app.** `swift test` runs unsandboxed;
  extension *processes* may need entitlement additions that only show against
  the sandboxed app, and 7.1 loads no context anyway. First live check is owed
  once a context actually loads (7.3).

### Phase 7.2 — `.crx`/`.xpi` install helper (2026-07-24)

- **Deviation from the plan, verified against the header: store a ZIP, not an
  unpacked directory.** `WKWebExtension.extension(resourceBaseURL:)` reads "a
  directory … *or a ZIP archive* containing a `manifest.json`" (SDK header). So
  `ExtensionInstaller` normalises each bundle to a ZIP and stores
  `Extensions/<slug>.zip` — no hand-rolled ZIP extractor (no central-directory
  parse, no deflate, no zip-slip surface) for a tree WebKit re-reads anyway. See
  ADR 011.
- **`ExtensionArchive` is the pure part**: detect format by magic bytes (`Cr24`
  / `PK\x03\x04`), and for a `.crx` strip the signed header — CRX2 (pubkey+sig)
  and CRX3 (protobuf header), little-endian offset math — to recover the
  embedded ZIP. `.xpi`/`.zip` pass through. No file system, no WebKit; unit
  tested against synthetic CRX2/CRX3 blobs (the CRX3 offset test was confirmed
  red against an off-by-header bug, then restored).
- **`ExtensionInstaller` is the I/O part**: `install(from:)`,
  `installedExtensions()`, `remove(slug:)` over the on-disk library. Slug from
  the source filename stem, sanitised so a hostile name cannot escape the
  directory. Reinstalling overwrites in place. It is WebKit-free — pure file +
  byte work — living in `BrowserExtensions` because that is the subsystem.
- **MV3 enforcement is deferred to load (7.3).** Nothing in 7.2 reads inside the
  ZIP; `WKWebExtension.manifestVersion` is where "MV3 only" gets enforced (WebKit
  itself accepts MV2, so it is our policy at load, not WebKit's).
- **Not wired to the app yet** and not driven live: no UI calls `install`, and
  nothing loads the stored ZIP. That is 7.3+. The installer's directory will be
  `support/Extensions/` when wired.

### Phase 7.3a — extension load path + MV3 enforcement (2026-07-24)

7.3 split into 7.3a (loading, done here) and 7.3b (the tab/window model). The
split is deliberate: **the whole `WKWebExtensionControllerDelegate` is
`@optional`** (verified in the header), so `controller.load(context)` succeeds
with no delegate — the extension just sees an empty browser. That makes the
loading path buildable and unit-testable *now*, while the tab/window model needs
`TabStore` injection and a hands-on check with a real extension (§11), so it is
its own slice.

- **`WebKitExtensionHost.load(_:in:)`**: `WKWebExtension(resourceBaseURL:)`
  (async throws) → **reject `manifestVersion < 3`** → `WKWebExtensionContext(for:)`
  with `uniqueIdentifier = slug` (stable per Space+slug; the controller is
  already per-Space) → `controller.load(context)`. Tracks loaded contexts keyed
  by Space then slug; `unload(slug:in:)` and `loadedExtensions(in:)` round it
  out. All three are on the WebKit-free `ExtensionHost` protocol
  (`LoadedExtension` in, out — no `WK*`).
- **MV3 is our policy, not WebKit's.** WebKit loads MV2 fine (the break-test
  confirmed it loaded an MV2 bundle when the gate was weakened). We reject it at
  load, the first point the manifest is parsed.
- **Verified against real WebKit in `swift test`**: a synthetic MV3 manifest in a
  temp directory (which `resourceBaseURL` accepts, same as a ZIP) loads into a
  real per-Space controller; MV2 is rejected with
  `unsupportedManifestVersion(2)`; a manifest-less directory throws
  `unreadableBundle`; loads are per-Space isolated. 7 tests; the MV3 gate was
  confirmed red against a `>= 2` weakening.
- **Not yet driven in the real app.** `swift test` is unsandboxed; extension
  *processes* (background service workers) may need entitlement additions that
  only surface against the sandboxed app, and a synthetic inert extension
  exercises no worker. First real-app check comes with 7.3b, when a loaded
  extension has tabs to see.

## Next steps, in order

**M7 is in progress.** 7.1, 7.2, 7.3a landed (above). Continue with **7.3b** —
the `WKWebExtensionTab`/`WKWebExtensionWindow` model over `Tab`/`Pane`/main
window, feeding each per-Space controller via its (optional) delegate
(`openWindowsFor:`, `focusedWindowFor:`, `didOpenTab:`/`didCloseTab:`/
`didActivateTab:`). All `WKWebExtensionTab`/`Window` methods are optional, so a
minimal-but-honest adapter is fine to start. **The hard seam:** the adapters
live in `BrowserExtensions` (WebKit) but need tab state from `TabStore`
(`BrowserStore`, above them), so define a WebKit-free model protocol *in*
`BrowserExtensions` and have the Store conform (inject downward, per §3.5). Note
`webView(for:)` must return a pane's live `WKWebView`, which the engine holds
privately — an engine-layer accessor is needed (WK-typed, engine↔extensions
only). **Verify with a real extension in the real app** (§11); load is unit-
covered but the tab model is not observable without a page. Then 7.4 (per-Space
enable/disable + a schema decision: enablement table vs per-Space prefs), 7.5
(action popover + permission UI), 7.6 (soak, then stop for review). Content
blocking (§4.8) was deferred to its own later milestone.

The agreed plan below still holds for the remaining phases. **M6 is complete**;
its 30-minute soak passed (2026-07-24).

The **M7 (Extensions)** plan below is agreed with the user; **the open decision
is settled: extension contexts are per-Space** (now ADR 011, and 7.1 built the
wiring for it). Read §4.7 first, and verify every `WKWebExtension*` symbol
against the SDK headers before use — they were spot-checked on 2026-07-24 (macOS
26.5 SDK) and all exist, but re-verify signatures.

**M7 — Extensions, per-Space (agreed plan)**

- **Decision: per-Space contexts.** Each Space loads its own copy of an enabled
  extension — isolated storage, permissions, background workers. Fits Spaces'
  existing cookie/storage isolation. Cost: a background service worker is one
  process _per Space it's enabled in_; surface per-Space extension memory in the
  UI (§6.6). Supersedes the §12 open decision → **ADR 009**.
- **Per-Space isolation is first-class:**
  `WKWebExtensionController.Configuration.configurationWithIdentifier:(NSUUID)`
  gives persistent per-identifier on-disk storage — the analogue of
  `WKWebsiteDataStore(forIdentifier:)`. So **one `WKWebExtensionController` per
  Space**, config keyed by the Space id, its `defaultWebsiteDataStore` = the
  Space's store, wired via `WKWebViewConfiguration.webExtensionController`.
- **Loading:** `WKWebExtension.extension(resourceBaseURL:)` (an unpacked dir) →
  `WKWebExtensionContext(for:)` → `controller.load(context)`. `.crx` (Chrome) and
  `.xpi` (Firefox) are both ZIPs to unpack into
  `~/Library/Application Support/Browser/Extensions/`; MV3 only.
- **The bulk of the work is the tab/window model:** implement the
  `WKWebExtensionTab` / `WKWebExtensionWindow` protocols over `Tab`/`Pane`/main
  window and feed each controller via its delegate
  (`openWindowsForExtensionContext:`, `focusedWindowFor…`, `didOpenTab:` /
  `didCloseTab:` / `didActivateTab:`). The `WKWebExtensionTab` methods map almost
  one-to-one onto `Tab`/`Pane` + engine calls.
- **Toolbar UI (§4.7):** `context.action(for: tab)` → `WKWebExtensionAction`
  (icon/badge/popover); delegate `presentPopupForAction:` surfaces the popover in
  the sidebar header; `didUpdateAction:` for badge changes. Permissions via
  `grantedPermissions` + delegate prompts.
- **Layering call for the user:** §7.1 says `BrowserEngine` is the only WebKit
  importer, but the host needs WebKit too. Recommendation: a `BrowserExtensions`
  target that imports WebKit + Engine, behind an `ExtensionHost` protocol (no
  `WK*` type reaches Store/UI), and amend §7.1 to "the **engine layer** is the
  WebKit boundary." Confirm before building 7.1.
- **Phases (each a commit, done-when):** 7.1 seam + package + per-Space controller
  wiring · 7.2 `.crx`/`.xpi` unpack helper · 7.3 tab/window model · 7.4 per-Space
  enable/disable (needs a schema decision — enablement table vs per-Space prefs) ·
  7.5 action popover + permission UI · 7.6 soak with N extensions across 3 Spaces,
  then stop for review. Content blocking (§4.8) is independent and can ride along
  or be its own milestone — **ask the user**.
- **Reminder:** **do not reimplement the WebExtensions API** (Orion's ~70% after
  six years). Coverage = Apple's framework = Safari's. Entitlements may need
  additions for extension processes — `swift test` runs unsandboxed and cannot
  catch that, so verify against the real app (as with print/downloads).

Two hands-on checks are still owed on M6 work, neither blocking: the swipe
gesture on a real trackpad (only its logic and shared render path are covered),
and Reduce Motion toggled in System Settings.

Not blocking, and worth doing whenever: the Instruments pass §6.7 wants
(Allocations/Leaks, never run), and sidebar-scroll fps now that screen recording
is available. `BrowserUITests` now exists (it did not, which is why panel sizing
broke twice with a green suite), but it holds only the drag payload — panel
sizing is still uncovered.

## Carried debt

- ~~Drag a tab into a split does not work yet.~~ **Done 2026-07-23**, described
  under "How drag-to-split works" below.
- **`cliclick` is installed** and is how the divider drag was finally verified.
  Use `dm:` (not `m:`) between `dd:` and `du:` — `m:` sends _mouseMoved_, which
  a SwiftUI `DragGesture` tolerates but an AppKit drag session ignores.

- ~~Double-click on the top strip no longer zooms the window.~~ **Fixed
  2026-07-24.** `TitlebarDoubleClickMonitor` — a local `.leftMouseDown` monitor,
  not an overlay view, so it intercepts only the double-click in the top
  `titlebarInset` strip (past the traffic lights, main window only) and never
  blocks an ordinary click on the page beneath. It honours the system
  "double-click title bar to" preference, defaulting to zoom. Verified live with
  `cliclick dc:` — the window fills the screen and a second double-click
  restores it.

- ~~No 30-minute soak has been run, for any milestone.~~ **Cleared 2026-07-23.**
  Soak run and every §6.1 budget measured; all pass, with the numbers and their
  caveats in [SMOKE.md](SMOKE.md). No leak: app footprint 70 MB → 62 MB over 30
  minutes, total flat at ~720 MB. Headroom is large — the app process is using
  under half its 150 MB target with 12 live views.
- **Instruments passes (§6.7) are still not done** for M1/M3. The numbers above
  come from `footprint`, CPU-time deltas, `sample`, and signposts, which is
  enough to clear the §8 gate but does not give first-_painted_-frame timings or
  an Allocations/Leaks trace.
- **Sidebar scroll (120 fps) is still unmeasured**, but no longer known to be
  unmeasurable: screen recording is granted now, so a capture-based approach is
  worth trying before declaring it impossible.
- ~~Nobody has logged into two real Google accounts by hand.~~ **Done
  2026-07-23** — verified by hand against real Google auth, M2's done-when.
- ~~The command bar's _appearance_ is unverified.~~ **Verified 2026-07-23** by
  screenshot, which is how the clipped result list below was found. A full
  visual sweep followed (sidebar, favicon fallback, progress bar, Space
  gradients, command bar navigation) — results in [SMOKE.md](SMOKE.md).
- **`FuzzyMatch` accepts any subsequence**, so `goo` matches "WKDownloadDelegate
  | Apple Developer Documentation". Weak matches rank last and are noise rather
  than wrong answers, but the bar fills with rows a user would not call
  matches. Wants a quality floor, not just a score. Found in the visual sweep.

### From the swipe session (2026-07-24)

- ~~The swipe monitor can hijack a page's horizontal scroll.~~ **Fixed
  2026-07-24.** The Space-switch swipe now engages only over the sidebar
  (`engageMaxX` in `SpaceSwipeMonitor`, kept at the sidebar's right edge by
  `RootView`), so a swipe over the page reaches `WKWebView` — both its horizontal
  scroll and its back/forward navigation gesture, which the Space swipe used to
  steal. Reported by the user: a two-finger swipe to go back/forward switched
  Space instead. See "Swipe-driven Space switching".
- **A phased two-finger swipe is not scriptable** — verify the release spring,
  rubber-band feel, and gradient tracking by hand on a trackpad. Everything
  around it is covered (unit tests + the shared discrete-switch render path).

### From the M6 session (2026-07-23)

- **Reduce Motion routing is complete, but never toggled live.** Every animation
  goes through `Motion.respectingReduceMotion` (audited), and the sidebar reveal
  now fades rather than slides under the setting. Nobody has turned the setting on
  in System Settings and watched — see "Animation and Reduce Motion pass".
- **The reveal strip's click pass-through is untested in practice.** `hitTest`
  returns nil so clicks _cannot_ hit it, but as laid out today the 6-point strip
  overlaps only the content card's 8-point inset, not the web view — so the
  mechanism has never actually been exercised. It will matter the moment that
  inset changes.
- **`Cmd+Shift+D` on a tab that already has four panes** opens the command bar,
  and the store then declines the split. Nobody has checked what that looks
  like; the bar most likely just dismisses with no feedback, which reads as the
  command being broken.
- **`Cmd+Enter` from split mode** is unit-tested (forces a new tab, not a pane)
  but unconfirmed by hand.
- **An archived-tab result in split mode reopens as a tab, not a pane.**
  Deliberate — `restoreArchived` builds a tab — but it is the one destination
  the mode does not honour, and the row label does not say so.
- **The favicon loader is `URLSession`**, so it sends CFNetwork's User-Agent
  rather than the browser's. Harmless today; worth knowing if a site ever serves
  us a favicon it would not serve Safari.
- **One launch came up with the sidebar expanded** when the stored preference
  said collapsed, and it has not reproduced in 5 consecutive launches since. If
  it returns, suspect `WindowAccessor` reporting a window before the scene has
  one.
- **History records challenge pages** — a Cloudflare "Just a moment…" entry is
  in there. `recordVisit` skips blank and error pages, but not interstitials.

## Deviations from the spec

Each has an ADR; the spec text was updated in the same commit.

- `WKProcessPool` unused — Apple deprecated it to a no-op (ADR 004)
- `BrowserStore` is a package the §3.5 list omitted (ADR 005)
- Audio playback detected by user script, not the SPI everyone else uses (ADR 008)
- `Cmd+T` opens the command bar per §4.4; plain new tab moved to `Cmd+N`
- **Every way of making a tab or a pane opens the command bar first**, not a
  blank page: `Cmd+T`, the sidebar's New Tab button, and `Cmd+Shift+D`. The bar
  is a three-mode thing now (`CommandBarMode`), and where a result lands is an
  `ActivationDestination` rather than a `forceNewTab` flag — a Bool cannot say
  which of three places a result belongs in. `Cmd+N` still opens a plain blank
  tab, which is the escape hatch when you genuinely want one.
  In `.newPane` mode, choosing an _already-open tab_ moves it into the split
  exactly as dragging it there would (4.5) rather than duplicating it, and the
  row says "Move to Split" instead of "Switch to Tab" — §4.4 requires a row to
  announce what Return does before it happens.
- `Cmd+T` opens results in a _new_ tab, `Cmd+L` navigates the _current_ one.
  §4.4 originally had Return always navigate the current tab, which meant
  `Cmd+T` replaced the tab you were on — the one thing nobody expects it to do.
  Spec text updated in the same commit.

## Open decisions (BROWSER_SPEC §12)

- ~~Extension contexts per-Space or global (M7)~~ Resolved: per-Space, one
  `WKWebExtensionController` per Space (ADR 011).
- Open for 7.4: how per-Space enablement is stored — an enablement table vs
  per-Space prefs. Decide when 7.4 starts.
- Open for the user: whether content blocking (§4.8) rides M7 or is its own
  milestone. **Answered 2026-07-24: its own later milestone.**

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
  Now `surface(for:in:)` per pane. Worth knowing how it was caught: the _e2e_
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
