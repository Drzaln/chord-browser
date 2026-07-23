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
| **Completed** | M1 Browse, M2 Spaces, M3 Command bar, M4 Session restore + downloads |
| **Next** | M5 — Split view + Little Arc |
| **Branch** | `main` — single branch, linear history, one commit per milestone |
| **Tests** | 150 passing (136 unit + 14 end-to-end) |
| **Schema** | v3 (`v1_initial`, `v2_add_spaces`, `v3_history_and_archive`) |
| **Toolchain** | Swift 6.3.3, Xcode 26.6, macOS 26.5 host, target floor 15.4 |

**The §6.1 performance gate passes** as of 2026-07-23, covering M1–M3 together.
Numbers and method in [SMOKE.md](SMOKE.md). Two gaps remain, neither blocking:
no Instruments pass, and sidebar scroll cannot be measured without screen
recording. See Carried debt.

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
  BrowserStore/          TabStore (+Spaces/+Sweep/+CommandBar), PaneRuntime, AppEnvironment
  BrowserUI/             SwiftUI + command bar panel. Imports Engine but never WebKit.
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

**The panel must size itself from its content.** It shipped in M3 with a fixed
`640x60` frame and an `autoresizingMask` on the hosting *view* — which makes the
view follow the window, never the reverse. The result list rendered correctly
and was clipped away entirely; every M3 behavioural check passed because Return
still activated the right row. It is an `NSHostingController` with
`sizingOptions = [.preferredContentSize]` now, and `setFrame` is overridden to
anchor the top edge, because AppKit preserves the bottom-left corner on resize
and the bar would otherwise crawl upward as you type.

## Carried debt

- **Drag a tab into a split does not work yet** (§4.5). Everything up to the
  payload is correct and verified with `cliclick`: the drag starts, the pane
  highlights, `prepareForDragOperation` and `performDragOperation` both fire,
  and the pasteboard advertises `com.rizal.browser.tab`. The payload arrives as
  **zero bytes** — `data(forType:)` returns empty `Data`, not nil, via both the
  pasteboard and `pasteboardItems`. Tried and rejected: SwiftUI `onDrop` (the
  `WKWebView` wins the destination search), a lazy
  `registerDataRepresentation`, and an eager
  `NSItemProvider(item:typeIdentifier:)`. Next thing to try is dropping
  `NSItemProvider` entirely and making the sidebar row an AppKit drag *source*
  (`beginDraggingSession` with an `NSPasteboardItem` carrying the string), which
  puts both ends under our control.
  Two findings from this worth keeping regardless:
  - The destination must return an operation the **source** offers. SwiftUI's
    `onDrag` advertises `.copy` (mask 1); returning `.move` makes AppKit refuse
    the drop, so the pane highlights on hover and release does nothing.
  - `WKWebView` registers for dragged types, and AppKit picks the *deepest*
    registered view under the cursor, so any SwiftUI-level drop target over web
    content loses. An AppKit destination mounted above it works — but only
    while a drag is in flight, or it eats ordinary clicks.
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
- **Known latent bug, will bite in M5.** Capture and resolution iterate *every*
  pane of a tab, but `surface(for:)` gates only `tab.focusedPaneID`. With one
  pane per tab those are the same thing, which is why M4 could not tell them
  apart. M5 renders every pane, so a non-focused pane can have its web view
  built before its blob resolves — it will load the bare URL and throw the
  restored state away. Fix the gate per pane, and cover it with an e2e test that
  restores a two-pane tab and asserts the *non-focused* pane kept its
  back/forward history.
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
- Add e2e coverage alongside: the harness (`E2EHarness`) makes a second store
  over the same directory to simulate relaunch, which is exactly the shape M4's
  acceptance test needs.
