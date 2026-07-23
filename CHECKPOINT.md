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
| **In progress** | M6 Polish — sidebar hide/reveal, favourites, find-in-page, command-bar entry points, swipe Space switching done |
| **Next** | M6's remainder: cross-section drag, animation tuning, print, PDF |
| **Branch** | `main` — single branch, linear history, one commit per milestone |
| **Tests** | 212 passing (193 unit + 19 end-to-end) |
| **Schema** | v3 (`v1_initial`, `v2_add_spaces`, `v3_history_and_archive`) |
| **Toolchain** | Swift 6.3.3, Xcode 26.6, macOS 26.5 host, target floor 15.4 |

**The §6.1 performance gate passes** as of 2026-07-23, re-run for M5 with split
view and Little Arc in the fixture. App 58 MB, total 498 MB, idle 0.083%
visible / 0.006% occluded — every budget clear by a wide margin, and no leak
over 30 minutes. Numbers and method in [SMOKE.md](SMOKE.md); the runner is
`scripts/soak.sh` (`seed` then `run`). Two gaps remain, neither blocking: no
Instruments pass, and sidebar scroll is still unmeasured. See Carried debt.

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
finish M6 — swipe-driven Space switching, cross-section drag-and-drop, an
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
  exit *regardless of hit testing*, so `hitTest` returns nil and clicks pass
  straight through.
- **The traffic lights are hidden while the sidebar is** (`TrafficLights`).
  AppKit puts them at a fixed offset from the window's top-left regardless of
  what is underneath, so with no sidebar they land on the page.
- **Hide-on-exit is delayed and cancellable** (`Motion.sidebarCollapseDelay`).
  Zero delay makes the sidebar snap shut while the pointer travels toward a row
  near its edge.
- The revealed sidebar is a floating card — rounded, shadowed, inset — and the
  in-lane one is flush. That is Arc, and it is what makes the revealed state
  read as *over* the content rather than part of it.
- The collapsed state is a window preference in `UserDefaults`, not a schema
  column: it is not user data and has no business carrying a migration.

### Favourites (pinned tabs)

- `TabPlacement.pinned` and `setPinned` existed from M1, in the model *and* the
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
- An emptied field reports *nothing* rather than "not found", or the bar flashes
  red on every backspace as a query is deleted.

### Swipe-driven Space switching (4.2)

- **Raw scroll-phase `NSEvent`, not a gesture recogniser** — a recogniser
  reports a swipe after the fact and cannot drive progress continuously, which
  is the whole feel. `SpaceSwipeMonitor` installs a *local* event monitor
  (`addLocalMonitorForEvents(matching: .scrollWheel)`) so it sees the event
  before any view dispatch and can consume a swipe the `WKWebView` would
  otherwise scroll. It engages only when a gesture *begins* with
  `abs(scrollingDeltaX) > abs(scrollingDeltaY)` **and** carries a real trackpad
  `phase` — a mouse wheel has no phase and a vertical scroll reaches the page.
- **The maths is pure and lives in Core** (`SpaceSwipe`): full-swipe distance,
  commit threshold, rubber-band curve, and the stop-for-stop gradient blend
  (`ColorHex.lerp`). Tested without a trackpad.
- **The gradient blend is continuous across the commit.** On release past the
  threshold the monitor springs `spaceSwipeProgress` to `±1` and only *then*
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
  and the *rendering* path is shared with discrete `Cmd+1…9` switching, which was
  screenshot-verified (blue Space → red Space). The continuous gesture itself
  still wants a hands-on trackpad check.

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
- `TestHTTPServer` records request headers per path. Per *path* because a page
  load is followed by a favicon fetch, and that one comes from `URLSession`
  with CFNetwork's own UA — "the last request" answers about the wrong one.

## Next steps, in order

1. **Cross-section drag-and-drop** (4.1) — reorder within a section, drag
   across sections to change placement, drag onto a Space to move between
   Spaces. Start from `TabDragSource`: the row is already an AppKit drag
   source, so this needs a *destination* beside it, not a second mechanism.
   Do not reach for SwiftUI `onDrag`/`onMove`; see "How drag-to-split works".
   Dragging a row into the favourites grid should pin it — `setPinned` already
   exists and the grid already renders from `pinnedTabs`.
2. **Animation tuning pass** (5). Everything is already named in
   `Motion.swift`; this is a sit-and-look job, and Reduce Motion needs checking
   at the same time — it is currently unverified for the sidebar reveal and the
   swipe release.
3. **Print** — `WKWebView.printOperationWithPrintInfo(_:)`, confirmed present
   in the SDK headers (macOS 11+).
4. **PDF viewing** — check what WebKit already does before building anything.
   It may be free.
5. **Re-run the soak** (`scripts/soak.sh seed` then `run`). §8 gates every
   milestone on it, and M6 adds a permanent tracking area plus a find bar that
   holds a cancellable task — both cheap, neither yet measured over 30 minutes.

Then stop for review. M7 (Extensions) is deliberately last.

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
### From the swipe session (2026-07-24)

- **The swipe monitor can hijack a page's horizontal scroll.** A trackpad
  gesture that *begins* more horizontal than vertical is claimed for a Space
  switch, so a wide table or a horizontally-scrolling page swiped sideways
  switches Space instead of scrolling. This ambiguity is inherent to the gesture
  and Arc resolves it the same way; the `.began`-dominance gate is the only
  disambiguation. If it proves annoying, the next lever is a larger horizontal
  bias or restricting the monitor to swipes that start over the sidebar.
- **A phased two-finger swipe is not scriptable** — verify the release spring,
  rubber-band feel, and gradient tracking by hand on a trackpad. Everything
  around it is covered (unit tests + the shared discrete-switch render path).

### From the M6 session (2026-07-23)

- **Reduce Motion is unverified for the sidebar reveal.** The animation is
  routed through `Motion.respectingReduceMotion`, but nobody has turned the
  setting on and looked. Same for the pinned grid.
- **The reveal strip's click pass-through is untested in practice.** `hitTest`
  returns nil so clicks *cannot* hit it, but as laid out today the 6-point strip
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
  In `.newPane` mode, choosing an *already-open tab* moves it into the split
  exactly as dragging it there would (4.5) rather than duplicating it, and the
  row says "Move to Split" instead of "Switch to Tab" — §4.4 requires a row to
  announce what Return does before it happens.
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
