# Checkpoint

Living handoff document. **Update it in the same commit as the work it
describes** — a stale checkpoint is worse than none, because the next agent will
believe it.

Read [BROWSER_SPEC.md](BROWSER_SPEC.md) first. It is the contract; this file is
only the current position within it.

---

## Status

|                                  |                                                                                                                                                                                                   |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Completed**                    | M1 Browse, M2 Spaces, M3 Command bar, M4 Session restore + downloads, M5 Split view + Little Arc, M6 Polish                                                                                       |
| **Completed (M7)**               | **M7 Extensions** — 7.1–7.6 all done and **VERIFIED LIVE**                                                                                                                                        |
| **Completed (content blocking)** | **§4.8 — C1–C4 + chunking, all VERIFIED LIVE** (converter, compile/cache/attach, weekly refresh, full-list chunking, soak).                                                                       |
| **Shipped**                      | **Extensions and content blocking are ON by default — `FeatureFlags` deleted (§7.4).** Both always wired in `AppEnvironment.live()`. **Every spec milestone (M1–M7) + content blocking is done.** |
| **Next**                         | **No assigned task.** Open, non-spec, **ask before building** (§11): per-site content-blocking whitelist / runtime disable toggle; per-domain UA override map (§9.6).                            |
| **Post-M7 (non-spec)**           | Pinned tabs (three tiers, v8) · folders (v7) · per-Space history (v6) · **multiple windows + window layout (v9)** · **per-site camera/mic/notification permissions (v10, re-scoped v11)** · web notifications · YouTube ad skipping · UA setting · General settings. See §4.9 of the spec and the dated sections below. |
| **Branch**                       | `main` — single branch, linear history, one commit per milestone                                                                                                                                  |
| **Tests**                        | **423 passing** (`swift test`, 68 suites), measured 2026-07-31                                                                                                                                   |
| **Schema**                       | **v11** — `v1_initial` … `v8_pinned_home_url`, `v9_window_layout`, `v10_site_permissions`, `v11_site_permissions_per_space`                                                                       |

**AdBlock cannot block on WebKit — DNR rule limit (2026-07-25, diagnosis).**
After the two fixes below, **Enhancer for YouTube works** (content script) and
AdBlock's popup loads, but AdBlock still does not block ads. This is **not a
fixable bug** — it is a WebKit platform limit:

- AdBlock is fully wired: DB confirms `<all_urls>` + all declared API permissions
  granted for its slug. Host access is not the problem.
- AdBlock blocks via `declarativeNetRequest` with **63,466 enabled static rules**
  across its default rulesets — one single ruleset is **53,575 rules**.
- WebKit rejects DNR rulesets over its ceiling. This is the _same_ limit our own
  content blocker chunks around: `ContentBlocker.maxRulesPerList = 50_000`
  because `WKContentRuleList` compilation caps ~50k/list. A 53k-rule ruleset is
  over it, so AdBlock's rules never load and it blocks nothing.
- **No code fix.** We cannot repackage a third-party extension's rulesets. The
  right answer for the user is the **built-in content blocker** (on by default),
  which is fed the same EasyList/EasyPrivacy data, uses native `WKContentRuleList`
  (not DNR), and chunks at 50k so it loads the full ~137k rules. AdBlock the
  extension is redundant here and can be uninstalled.
- UI note (fixed 2026-07-25 in commit `5455c7e`): toolbar buttons used to render
  only after a sidebar collapse/re-expand — `load`/`unload` now fire
  `onActionsChanged` so the header refreshes on launch. (Was: `ExtensionActionsBar`
  in the header only re-read `actions(in:)` on a token bump that never happened at
  load time.)

**Frosted-glass chrome (2026-07-25).** The docked sidebar and the border frame
now use the same `.ultraThinMaterial` frosting the collapsed sidebar had. Three
coordinated changes (verified live):
- `SidebarView` background: `.ultraThinMaterial` in **both** modes (was
  `.regularMaterial` when docked); Space-gradient tint at 0.1 floating / 0.28
  docked.
- `RootView.spaceBorderTint`: base is now `.ultraThinMaterial` (was opaque
  `windowBackgroundColor`) + gradient tint at 0.4.
- `RootView.configureWindow()` sets `window.isOpaque = false` /
  `backgroundColor = .clear` (called from the existing `onChange(of: window ==
  nil)` — **not** inline in `body`, which is already at the SwiftUI type-checker's
  complexity limit; adding a multi-line closure there triggered "unable to
  type-check in reasonable time"). The material only reads as glass because the
  window is non-opaque; the web content card stays opaque so pages are unaffected.

**Rebrand → "Chord" (2026-07-25).** User-facing name is now **Chord
Browser** (icon: a white chord across a coral→magenta gradient circle,
`#FF512F`→`#DD2476`). Applied **display-only** to avoid data loss:

- `CFBundleDisplayName = "Chord"` (Info.plist) + window title in
  `BrowserApp.swift`. `PRODUCT_NAME`/target stay `Browser`; **bundle id stays
  `com.rizal.browser`** — it keys the on-disk profile, so renaming it orphans
  cookies/Spaces/extensions.
- Brand assets + rationale in `docs/branding/` (`chord-icon.svg`,
  `chord-icon-1024.png`, `BRANDING.md`). A ready `AppIcon.appiconset` is at
  `BrowserApp/Assets.xcassets/` but **needs a manual Xcode step** to wire (add
  the catalog to the target + set the app-icon name — both are `project.pbxproj`
  changes this repo excludes from commits).
- Icon is a circle on transparent; macOS masks to a squircle so it floats. A
  full-bleed variant is a quick follow-up if wanted.

**Ad-blocking & YouTube: why it works elsewhere but not here (design note,
durable).** Recurring user question — "Brave/Arc/Orion block YouTube ads with the
same extension, why can't mine?" The answer is always the **engine + extension
runtime**, never the extension or the filter lists:

- **The mechanism YouTube blocking needs:** YouTube serves video ads from the same
  domain and player as the video, so there is no ad URL to match. Defeating them
  needs **scriptlet injection** — arbitrary JS patched into YouTube's own page
  (null the ad objects, prune the ad data from the player response, fake
  ad-finished events). It also needs blocking `webRequest` for the general case.
- **Arc = Chromium.** Runs the _full_ Chrome extension engine for free: high DNR
  limits (hundreds of thousands of rules), blocking `webRequest`, content scripts,
  scriptlet injection. So AdBlock/uBO block YouTube ads there. Also true of Brave,
  Edge, Chrome.
- **Orion = WebKit, but Kagi _rebuilt_ the WebExtensions runtime** (~70% of the
  APIs, incl. `webRequest` blocking + scriptlets). That is why a WebKit browser
  _can_ run real uBlock Origin and block YouTube — it bypasses Apple's APIs.
- **Ours = WebKit + Apple's `WKWebExtension`.** DNR rule cap ~50k/list (same limit
  `ContentBlocker` chunks around), **no blocking `webRequest`, no scriptlet
  injection**. So AdBlock's rules are rejected and YouTube ads cannot be touched.
  This is inherent to the spec's WebKit-native, low-memory bet, not a bug.
- **uBlock Origin here:** classic uBO is **MV2 → rejected** by our MV3-only load
  guard (`WebKitExtensionHost.load`). uBO **Lite** (MV3) would install but is
  DNR-based → same rule-limit wall, and cannot block YouTube even when fully
  working. So "install uBO" does not help.

**Two (large) future options if Arc-level blocking is ever wanted — NOT started,
NOT in scope without an explicit ask (§11):**

1. **Chromium engine** — abandons the WebKit-native design that is the whole point
   of `BROWSER_SPEC`. Effectively a different browser.
2. **Custom WebExtensions/scriptlet engine on WebKit (the Orion route)** — a
   `webRequest`-style blocking layer + a `WKUserScript` main-world scriptlet/
   content-script injection system. A major new subsystem and a permanent
   cat-and-mouse with YouTube. A _minimal_ first slice would be `WKUserScript`
   main-world scriptlet injection for a **curated** site list — enough to prove the
   mechanism, far short of running uBO.

- **Server-side YouTube ads** (ad stitched into the video stream) can't be blocked
  by _anyone_ client-side, Orion/uBO included — worth remembering before promising.

**Streaming video quality: AV1 is software-only in our WKWebView (design note,
durable, verified 2026-07-30).** Recurring user question — "why does YouTube show
VP9 here but AV1 in Safari, and why do Instagram/Facebook Reels look soft?" On an
Apple-silicon Mac with a hardware AV1 decoder:

- **Not a decode-support gap and not the User-Agent.** `MediaSource.isTypeSupported`
  returns true for AV1, and our default UA is a full, correct Safari token
  (`…Version/26.5 Safari/605.1.15`) — verified against `postman-echo.com/get`,
  byte-identical to Safari's. Sites do not distinguish us by UA here.
- **The real lever is `navigator.mediaCapabilities.decodingInfo().powerEfficient`.**
  Sites pick a codec on hardware-decode, not raw support, to save battery. In our
  WKWebView the probe reports **AV1 `powerEfficient: false` (software), while VP9 /
  HEVC / H.264 are `true` (hardware)**. So YouTube serves VP9 (hardware here) and
  Meta's high-efficiency AV1 Reels ladder is skipped, dropping to the softer
  fallback. Safari gets hardware AV1 and is offered it.
- **Root cause:** macOS exposes the AV1 hardware-decode path to Safari (and holders
  of Apple's special browser entitlement), not to a general WKWebView-hosted app,
  which silently falls back to software AV1. **Not fixable in app code.**
- **Diagnostic:** the `Cmd+Ctrl+P` debug overlay reports per-codec `hw`/`sw`/`no`
  for the active tab (`WebEngine.codecSupport`, DEBUG-only, compiled out of
  release). Use it to re-check on a future macOS/WebKit.

**Extensions-still-not-working, 2nd fix (2026-07-25).** After the host-access
fix, AdBlock's popup showed "the AdBlock menu had trouble loading" and Enhancer
still did nothing. Root cause: an MV3 extension's declared **API permissions**
(`tabs`, `storage`, `scripting`, `declarativeNetRequestWithHostAccess`,
`webNavigation`, …) start in WebKit's "requested" state, not granted — a real
browser grants these at install without a prompt. A background service worker
that cannot use its declared APIs fails to start, which is the "menu had trouble
loading" symptom. Fix: in `WebKitExtensionHost.load`, after re-applying persisted
grants, `setPermissionStatus(.grantedExplicitly)` for every
`webExtension.requestedPermissions` (host access still gated behind the enable
prompt). Also log `context.errors` after load so a broken bundle is diagnosable.
**Not yet live-verified** — the test session had the real Arc browser open
alongside, our app's toolbar buttons were not rendering, and sandboxed-app logs
did not surface via `log show`; builds + 318 tests pass. AdBlock's actual
blocking still depends on WebKit's _partial_ `declarativeNetRequest`, so expect
limited blocking even with the popup fixed. Next agent: verify live (enable →
Allow → open a fresh page; click the AdBlock toolbar button and confirm its popup
renders) and check `context.errors` in Console.

**Extensions-not-working fix (2026-07-25).** User installed AdBlock + Enhancer
for YouTube (both MV3, unpacked fine) and neither worked. Root causes, both
fixed:

- **No host access, no prompt.** WebKit does not prompt for a required
  `host_permissions` extension, so a freshly enabled extension had no site access
  and sat inert. Fixed: `WebKitExtensionHost.promptForHostAccess(slug:in:)` reads
  `webExtension.allRequestedMatchPatterns`, prompts (reusing the 7.5c permission
  sheet), grants + persists on Allow, then fires `onHostAccessChanged`.
  `ExtensionsService.enable` calls it (user-initiated enable only; restore stays
  silent).
- **Controller not on existing tabs.** `WKWebViewConfiguration.webExtensionController`
  is set only at view creation, so tabs open before an extension was enabled
  never ran it. Fixed: `extensionControllerHandle(for:)` now `prepare`s on demand
  so **every** web view attaches a controller. `onHostAccessChanged` →
  `TabStore.reloadTabs(inSpace:)` reloads so content scripts inject into
  already-open pages.
- **Verified LIVE:** enabling Enhancer for YouTube surfaced a host-access prompt
  listing its real requested patterns (`*://www.youtube.com/*`, `/embed/`,
  `/shorts/`, `youtube-nocookie`…) read from the loaded `WKWebExtension`; Allow
  granted and the tab reloaded. This proves load + pattern-read + grant + reload
  all work. Enhancer (pure content script) should now function; **AdBlock depends
  on `declarativeNetRequest`, which WebKit supports but incompletely** — expect
  partial blocking, and it can never touch YouTube video ads.
- Updated `PerSpaceControllerTests` (controller now always attaches) and added
  `ExtensionsServiceTests.enablePromptsForHostAccess`.

**User-requested non-spec features shipped (2026-07-25):**

- **Settings sheet** (`Cmd+,`, app-menu _Settings…_), presented from `RootView`
  like the other sheets. Two sections behind a segmented picker.
- **Privacy & Data — clear browsing data.** `BrowsingDataType` OptionSet
  (WebKit-free, in Core) → `TabStore.clearBrowsingData` fans website types
  (cache/cookies/site-storage) to `WebEngine.clearWebsiteData` (clears each
  Space's `WKWebsiteDataStore` via `removeData(ofTypes:modifiedSince:.distantPast)`
  — data-type constants verified against SDK headers) and `history` to
  `HistoryRepository.deleteAllHistory` (new). Global across all Spaces;
  confirmation dialog; irreversible.
- **Extensions UI** — install a `.crx`/`.xpi` via `.fileImporter`
  (security-scoped access), per-Space enable/disable switch, uninstall (trash).
  New `ExtensionsService.remove(slug:from:)` unloads from every Space then deletes
  from the library. This closes the "no in-app extension install" gap.
- **Verified live:** launched the built app, `Cmd+,` opened the sheet, Privacy &
  Data section renders all four toggles + Clear Data + confirmation copy. (The
  Extensions-tab screenshot was blocked by a macOS screen-recording permission
  dialog — not clicked, being a system prompt — but the tab is the same
  `SettingsView` switch and its actions are unit-tested.)

**Toolchain:** Swift 6.3.3, Xcode 26.6, macOS 26.5 host, target floor 15.4 (SPM
platform raised from `.v15` to 15.4 in M7). (The schema row that used to sit here
said v5; the live number is in the Status table above — v11.)

**The §6.1 performance gate passes** — re-run for M6 on 2026-07-24 with the
swipe scroll monitor, the sidebar drop layer, and the find bar's cancellable
task all in play. App process flat at 40–50 MB (43 MB at end), total settled at
~410 MB, no leak over 30 minutes. Every budget clear by a wide margin. Numbers
and method in [SMOKE.md](SMOKE.md); the runner is `scripts/soak.sh` (`seed` then
`run`, `restore` to put the real session back). Two gaps remain, neither
blocking: the full Instruments GUI trace (SwiftUI body counts, Energy Log) and
sidebar scroll are still unmeasured — but the §6.7 **Leaks** pass is now done and
clean (2026-07-25, framework noise only). See Carried debt.

## Kickoff prompt for the next session

Paste this whole block. It is deliberately blunt about the traps, because every
one of them has already cost a session here.

```
Read BROWSER_SPEC.md and CHECKPOINT.md in full before writing any code.

**Every spec milestone is done.** M1–M7 (Extensions) and the content-blocking
milestone (§4.8) have all shipped on `main`, verified live. Both extensions and
content blocking are ON by default — the `FeatureFlags` struct was deleted (§7.4).
A run of agreed post-spec additions has landed since (BROWSER_SPEC §4.9): multiple
windows, folders, per-Space history, per-site camera/mic/notification permissions,
web notifications, YouTube ad skipping, and the General settings pane.
Single `main` branch, **423 tests** passing, `./scripts/prepush.sh` green,
**schema v11**.

There is **no assigned next task** — wait for the user to pick one. The only
follow-ups on the board are NON-SPEC UI features, so do NOT start any of them
without the user asking (§11 forbids adding out-of-scope features):
  - **Per-site whitelist / disable** — the machinery exists: add an
    `ignore-previous-rules` `WKContentRuleList` keyed to the current host, or clear
    lists on that host. See `ContentBlocker` / `WebKitEngine.applyContentRuleLists`.
  - **Runtime settings toggle** for content blocking (and/or extensions) — a small
    settings surface that re-attaches or clears the lists via
    `engine.applyContentRuleLists`.
  - **Per-domain User-Agent override map** (§9.6) — the UA setting is global today.
Also open, both non-blocking: the full Instruments GUI trace (SwiftUI body counts,
Energy Log — not automatable here; the §6.7 Leaks pass is done and clean), and
sidebar-scroll fps. Content blocking's tail-coverage is already handled (the full
~137k rules are chunked in, not capped at 50k).

If the user does pick up content-blocking work, the design and live findings are
under "How content blocking works" in this file — especially: WebKit's url-filter
rejects disjunctions, compiling the whole list at once can hit an uncatchable
signal-6 abort (hence 50k chunks), and the compile completion handler is on the
main queue (a main-thread-blocking wait deadlocks — use await).

Stage with `git add -A ':!Browser.xcodeproj/project.pbxproj'` and commit/push
ONLY when the user asks.

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
  per-Space _contexts_ on a shared controller would not isolate. A private Space
  gets `.nonPersistent()`.
- **The engine layer is the WebKit boundary now, not just `BrowserEngine`.**
  §7.1 was amended: the extension host is a _second_ WebKit importer,
  `BrowserExtensions` (imports Core + Engine), rather than bloating the engine
  with an unrelated job. The two engine-layer packages share `WK*` types with
  each other; nothing WebKit-shaped crosses into Store or UI.
- **The seam is the `AnyWebSurface` trick.** `BrowserEngine` declares
  `ExtensionControllerHandle` (opaque; its `WKWebExtensionController` is
  _internal_ to the engine) and a WebKit-free `ExtensionControllerProviding`
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
  extension _processes_ may need entitlement additions that only show against
  the sandboxed app, and 7.1 loads no context anyway. First live check is owed
  once a context actually loads (7.3).

### Phase 7.2 — `.crx`/`.xpi` install helper (2026-07-24)

- **Deviation from the plan, verified against the header: store a ZIP, not an
  unpacked directory.** `WKWebExtension.extension(resourceBaseURL:)` reads "a
  directory … _or a ZIP archive_ containing a `manifest.json`" (SDK header). So
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
loading path buildable and unit-testable _now_, while the tab/window model needs
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
  _processes_ (background service workers) may need entitlement additions that
  only surface against the sandboxed app, and a synthetic inert extension
  exercises no worker. First real-app check comes with 7.3b, when a loaded
  extension has tabs to see.

### Phase 7.3b — the tab/window model (2026-07-24)

The `WKWebExtensionTab`/`WKWebExtensionWindow` model, so a loaded extension can
see and drive tabs.

- **Mapping: extension tab = our `Tab` (focused pane); extension window = a
  Space.** One window per Space, because extensions are per-Space (ADR 011): a
  Space's controller sees exactly its Space's tabs. In a split, the extension
  sees the focused pane — the one the user is reading, like find (§4.1).
- **The seam runs three ways.** (1) A WebKit-free `ExtensionTabModel` protocol is
  defined _in_ `BrowserExtensions` and `TabStore` conforms
  (`TabStore+Extensions.swift`) — the adapters sit below the Store, so tab state
  is injected downward (§3.5). (2) `webView(for:)` must return a pane's live
  `WKWebView`, which the engine holds privately, so `BrowserEngine` gained a
  `PaneWebViewProviding` protocol (WebKit-typed, kept **off** the `WebEngine`
  protocol; `AppEnvironment` forwards it as an existential without naming
  `WKWebView`). This is the one place the boundary runs Engine→Extensions; the
  7.1 controller handoff went the other way and could stay opaque. See ADR 011.
  (3) `TabStore` calls `extensionTabDidOpen/Activate/Close` on the host as tabs
  change, so each controller fires the matching WebExtensions events.
- **Adapters are `NSObject`s cached per (Space, tab) and per Space** — WebKit
  relies on object identity for tabs/windows, so the host hands back the same
  adapter each time. The host is now the `WKWebExtensionControllerDelegate`
  (`openWindowsFor:`, `focusedWindowFor:`), set on `prepare`.
- **All `WKWebExtensionTab`/`Window` methods are optional**, so the adapter
  implements the useful subset: window `tabs`/`activeTab`/`windowType`/`isPrivate`;
  tab `window`/`url`/`title`/`isSelected`/`indexInWindow`/`webView` + `activate`/
  `loadURL`/`reload`/`goBack`/`goForward`/`close`. `reload(fromOrigin:)` maps to a
  plain reload — WebKit exposes no from-origin bypass we can honour, and the
  argument is accepted rather than faked.
- **Lifecycle wiring is at three chokepoints only** — `newTab`, `select`,
  `closeTab`. Other creation paths (split panes, restore, adopt-orphans, Little
  Arc promotion) do **not** yet notify the host; an extension would not see tabs
  born that way until it re-queries. Noted as 7.3b debt; fold into 7.4.
- **Covered by tests, and now VERIFIED LIVE (2026-07-24).** 9 unit tests
  (adapter mapping/actions/`webView(for:)`/caching identity; Store snapshots +
  open/activate/close hooks, didOpen verified red). Then driven in the real
  sandboxed app with a synthetic MV3 content-script extension loaded into one
  Space: **its banner appeared on a page in that Space and not in another**, so
  content-script injection through our `WKWebView` and per-Space isolation both
  work end-to-end. No extra entitlement was needed for content scripts. Two
  findings came out of the drive, both expected and folded into later phases:
  - **Restored tabs never fire `extensionTabDidOpen`**, so the extension only
    saw _freshly opened_ tabs, not restored ones (the lifecycle debt above).
    Fold into 7.4: also notify on restore/split/adopt/promotion.
  - **Content scripts do not inject until host permissions are granted.** MV3
    `<all_urls>` is silently inert until `context.setPermissionStatus(
.grantedExplicitly, for: .allHostsAndSchemes())` (or the delegate prompt).
    That granting is **7.5** (permission UI); the check used a throwaway
    `grantAllHostsForTesting` to prove the pipe.
  - **Tooling note:** `os.Logger` notice/info logs were _not_ retrievable via
    `log show`/`log stream` on this machine — the reliable signal was a
    `screencapture` of the injected banner. Prefer screenshots over logs here.

### Phase 7.4 — per-Space enable/disable + persistence (2026-07-24)

- **Schema decision: a SQLite table, not per-Space prefs.** Enablement is
  behaviour-affecting user state, not a window preference, so it gets the
  migration/backup/row-mapping discipline of §7.2. Migration
  **`v4_extension_enablement`** — table `extensionEnablement(spaceId, slug)`,
  PK `(spaceId, slug)`, `spaceId` a cascade FK to `space` so deleting a Space
  reclaims its rows. Presence = enabled; disabling deletes the row. Additive,
  no existing data touched. Schema is now **v4**.
- **`ExtensionEnablementRepository`** in Core (WebKit-free, beside the other repo
  protocols), `SQLiteExtensionEnablementRepository` in Persistence.
- **`ExtensionsService`** (BrowserStore, WebKit-free) coordinates the three
  parts: `ExtensionInstaller` (library), `ExtensionHost` (load/unload), and the
  enablement repo. `enable` = load **then** persist (a bundle that fails to load
  is not left marked on); `disable` = unload then unpersist; `restoreEnabled`
  re-loads everything that was on, best-effort (a since-uninstalled bundle or a
  vanished Space is skipped and logged, never a launch failure).
- **Launch reload** runs _after_ `store.restore()` via a new `afterRestore`
  hook, because extensions load into Spaces and the Spaces must exist first.
  `AppEnvironment` wires it when the flag is on.
- **Lifecycle gap closed.** The only runtime tab create/remove path that did not
  already notify the host was **`moveTab` across Spaces** — now fires
  `didClose(fromSpace)` + `didOpen(toSpace)`. Everything else already routes
  through `newTab`/`closeTab`: Little Arc promotion calls `newTab`, drag-to-split
  absorb and last-pane close call `closeTab`, and restored/adopted tabs are seen
  via the load-time `tabs(for:)` query (extensions load after restore). A
  same-Space split adds a pane to an existing `Tab`, so there is no extension-tab
  change.
- **UI deferred to 7.5** (user's call): 7.4 is model + persistence only. No
  surface yet calls `enable`/`disable` — that is the popover work.
- **11 new tests** (4 enablement persistence incl. the v4 migration + per-Space +
  idempotency; 6 service enable/disable/restore with fakes; 1 `moveTab`
  close+open, verified red). All green; prepush green.

### Phase 7.5a — WK-free action model + `didUpdate` wiring (2026-07-24)

First slice of 7.5. Builds the WebKit-free action surface the sidebar header
(7.5b) will render; no UI yet.

- **`ExtensionActionSnapshot`** (BrowserExtensions, WK-free): slug, spaceID,
  `label`, `badgeText`, `presentsPopup`, `enabled`, `icon` as pre-rendered PNG
  `Data?`. The live `WKWebExtension.Action` never leaves the host — the icon is
  rasterised to PNG inside the host (`NSImage` → `NSBitmapImageRep` → PNG) so no
  AppKit image type crosses into UI (ADR 011).
- **`ExtensionHost.actions(in:)`** rebuilds snapshots from each loaded context's
  `context.action(for: nil)` (the default, tab-independent action) every call, so
  it always reflects the current label/badge/enabled state. Sorted by slug.
  Mirrored on `ExtensionsService.actions(in:)`.
- **The Swift type is `WKWebExtension.Action`, not `WKWebExtensionAction`** (the
  ObjC name is obsoleted in Swift), and the icon accessor is `icon(for:)` not
  `iconForSize:`. Both bit once during the build — noting so 7.5b/c don't repeat.
- **Change signal, not change data.** The host implements
  `webExtensionController(_:didUpdate:forExtensionContext:)` and, on a change,
  fires an `onActionsChanged` closure. `AppEnvironment` wires that to bump a new
  observable `TabStore.extensionActionsToken`; a SwiftUI view reading the token
  re-queries `actions(in:)`. No action data flows through the token — the
  WK-free values stay in the service, the token is purely an observation trigger.
- **Verified against real WebKit** (`swift test`): two MV3 bundles (one with
  `default_popup`, one without) load into a Space; `actions(in:)` returns both
  sorted by slug, and `presentsPopup` is `true`/`false` respectively — proving
  the snapshot reads real action state, not a guess. 2 new tests; 270 total.
- **No UI, no popover, no live-app check yet.** The header buttons and the
  popover are 7.5b; the `onActionsChanged`→UI path is wired but nothing renders
  it until then.

### Phase 7.5b — popover + sidebar-header buttons (2026-07-24)

The first extension UI. Behind `extensionsEnabled`, so with the flag off the
sidebar header is byte-for-byte what it was.

- **`ExtensionActionsBar`** (BrowserUI/Sidebar) renders one button per action in
  the active Space, in the header between the spacer and the collapse button. It
  reads `store.extensionActionsToken` to observe 7.5a's change signal and
  `store.activeSpace` to rescope, then queries `host.actions(in:)`. Icons come
  from the snapshot's PNG bytes (`NSImage(data:)`), falling back to
  `puzzlepiece.extension.fill`; the badge is a small red capsule.
- **The popover stays in the host** (ADR 011). Clicking a button calls
  `host.presentAction(slug:in:)`, which runs `WKWebExtensionContext.performAction`
  for the Space's active tab — that either fires the extension's click event or
  asks us to present its popup. The popup arrives at the
  `presentActionPopup` delegate, where the host shows
  `WKWebExtension.Action.popupPopover` (a ready-made `NSPopover` wrapping the
  popup `WKWebView`) relative to a registered anchor. No WebKit type crosses into
  UI — the button only hands over an `NSView` anchor.
- **The anchor is a zero-size `NSViewRepresentable`** behind each button
  (`PopoverAnchorView`), registered **weakly** with the host per (Space, slug) so
  a removed button clears itself with no explicit unregister. Both a user click
  and an extension-initiated popup resolve the anchor by `locate(context)` →
  (Space, slug) → the weak view.
- **Layering:** `BrowserUI` now depends on `BrowserExtensions` (to name
  `ExtensionActionSnapshot` and `any ExtensionHost`) — same as `BrowserStore`
  already does, and `BrowserExtensions`' public surface stays WebKit-free so UI
  imports no `WK*` type. The `NSView` anchor lives on the `ExtensionHost`
  protocol; `BrowserStore` is untouched and still imports no AppKit. `RootView`
  and `SidebarView` gained an `extensionHost` param (default `nil`); `BrowserApp`
  passes `environment.extensionHost`.
- **API note:** the click/popup entry point is
  `context.performAction(for:)` (verified in the SDK header — it triggers an
  event _or_ presents a popup per config, and popup actions require the
  `presentActionPopup` delegate). There is no per-action "click" method on
  `WKWebExtension.Action`.
- **NOT yet live-verified.** With no extension loaded, `actions(in:)` is empty
  and the header is unchanged, so there is nothing to screenshot until a dev
  extension with an `action` is loaded — the same scaffold 7.5c needs for its
  injection check. Fold the header-button + popover live check into 7.5c. Popup
  pages are the extension's own page and should render without host permissions;
  content-script injection is the part that waits on 7.5c's grants. Prepush
  green (270 tests + app build).

### Phase 7.5c — permission-grant UI + schema v5 (2026-07-24)

The load-bearing slice: content scripts stay inert until host permissions are
granted (the 7.3b finding), so this is what makes an ad-blocker or dark-mode
extension actually do anything.

- **Schema v5, `grantedPermission` table** (migration `v5_granted_permissions`):
  `(spaceId, slug, kind, value)`, all four the primary key so a repeat grant is
  idempotent; `spaceId` cascades from `space` like `extensionEnablement`.
  `kind ∈ {permission, url, matchPattern}` — WebKit's three prompt kinds. We
  persist grants **ourselves** and re-apply them on load, rather than trusting
  WebKit's own storage (the decision recorded for 7.5).
- **`GrantedPermissionsRepository`** (Core, WebKit-free) +
  `SQLiteGrantedPermissionsRepository` (Persistence): `granted` / `grant` /
  `revokeAll`. `GrantedPermissionKind` + `GrantedPermissionRecord` are the value
  types.
- **The three prompt delegates** on the host map one-to-one to the kinds:
  `promptForPermissions` (named API permissions), `promptForPermissionToAccess`
  (URLs), `promptForPermissionMatchPatterns` (host patterns). Each turns the
  WebKit set into strings (`permission.rawValue` / `url.absoluteString` /
  `pattern.string`), stashes the WebKit completion handler keyed by a fresh id,
  and surfaces a **WK-free `PermissionRequest`** through `onPermissionRequest`.
- **The flow is all-or-nothing per request** (how browsers present these). The
  Store queues requests in `pendingPermissionRequests`; `RootView` shows
  `ExtensionPermissionSheet` (Allow / Don't Allow) for the first one; the button
  calls `store.resolvePermissionRequest(id, allow:)` → `host.resolvePermission`,
  which answers WebKit (`respond(allow)` → full set or empty) and, on allow,
  persists the grant. An Esc / swipe dismiss is treated as a denial by the sheet
  binding's setter, so the completion handler is never dropped.
- **Re-apply on load:** `host.load` reads the Space+slug's grants and calls
  `context.setPermissionStatus(.grantedExplicitly, for:)` for each — permission,
  URL, or `WKWebExtension.MatchPattern(string:)` — **before** `controller.load`,
  so the extension starts with its permissions in place and does not re-prompt.
  Only `.grantedExplicitly` is ever set; denials are the WebKit default and are
  never persisted.
- **API notes (SDK-verified):** the Swift permission type is
  `WKWebExtension.Permission` (a String `rawValue` typed enum);
  `WKWebExtension.MatchPattern(string:)` is a **throwing** init (there is also a
  failable `matchPatternWithString:`); `context.webExtension.displayName` names
  the extension for the sheet. `setPermissionStatus(_:for:)` has three overloads
  (permission / URL / matchPattern) disambiguated by argument type.
- **Wiring:** `AppEnvironment` sets `host.permissionsRepository =
SQLiteGrantedPermissionsRepository(...)` and
  `host.onPermissionRequest = { store.pendingPermissionRequests.append($0) }`.
  `BrowserStore` still imports no AppKit/WebKit — the whole surface is WK-free
  values.
- **Tests:** 5 persistence (v5 migration, round-trip across all three kinds,
  idempotency, `revokeAll` scoping, per-Space) + 1 Store (resolve forwards to
  host and clears the queue). 276 total, prepush green.
- **VERIFIED LIVE (2026-07-24)** with a throwaway `devbanner` MV3 extension
  (action + `default_popup`, `optional_host_permissions: ["*://*/*"]`, an
  `<all_urls>` content script injecting a red banner), loaded into a Space via a
  temporary `AppDelegate` DEBUG hook (since reverted). All five behaviours held,
  each screenshot-confirmed:
  1. **Action button** appears in the sidebar header (the `puzzlepiece`
     fallback, since the dev extension ships no action icon) — 7.5b.
  2. **Popover** — clicking the button rendered the extension's own popup page
     ("DEV POPUP OK") in an `NSPopover` anchored under the button — 7.5b.
  3. **Permission sheet** — the popup calling `chrome.permissions.request(
{origins:["*://*/*"]})` surfaced our `ExtensionPermissionSheet`
     ("'Dev Banner' wants to read and change your data on: `*://*/*`") — 7.5c.
  4. **Grant → inject** — clicking Allow granted the match pattern and, after a
     reload, the content-script banner injected. The grant landed in
     `grantedPermission` (`devbanner | matchPattern | *://*/*`).
  5. **Persistence** — after a full quit + relaunch + reload, the banner injected
     **with no re-prompt**, so the persisted grant was re-applied via
     `setPermissionStatus` at load. `setPermissionStatus` **before**
     `controller.load` is correct — no ordering problem observed.
- **KEY FINDING — WebKit does not proactively prompt.** A fresh content-script
  extension with declared `host_permissions` stayed inert with **no** prompt on
  page load; the runtime prompt delegate only fired when the extension called
  `permissions.request` for an origin in **`optional_host_permissions`**
  (a declared `host_permissions` request did _not_ trigger a runtime prompt).
  Implication for a real ad-blocker/dark-mode extension whose manifest uses
  required `host_permissions`: our three prompt delegates will not fire on their
  own, so **7.5d (or a follow-up) should add a UI affordance to grant host access
  directly** (e.g. an "Enable on all sites" control that calls
  `setPermissionStatus(.grantedExplicitly, for: .allHostsAndSchemes())`), mirroring
  Safari's per-site toolbar menu. The prompt path is proven; the _trigger_ for
  required host permissions is the gap.
- **Tooling note (still true):** `os.Logger` logs were not retrievable via
  `log show`/`log stream`; `screencapture -x -o out.png` + Read the image was the
  reliable signal, exactly as in 7.3b.

### Phase 7.5d — background-worker presence + host-access toggle (2026-07-24)

Completes 7.5. Surfaces §6.6's per-Space cost and folds in the host-access
affordance the 7.5c live finding showed was needed.

- **Background-worker presence.** `LoadedExtension` gained
  `hasBackgroundContent` + `hasPersistentBackgroundContent`, read from
  `WKWebExtension.hasBackgroundContent` / `hasPersistentBackgroundContent` at
  load. A background service worker costs one process **per Space it is enabled
  in** (ADR 011), which the panel makes visible. **Memory itself stays deferred**
  — no `WKWebExtension*` API exposes per-process memory (re-checked); proc
  sampling is SPI-adjacent and was explicitly ruled out.
- **`ExtensionsPanel`** (BrowserUI) is a SwiftUI `.popover` off a new
  `ellipsis.circle` "Manage Extensions" button in the header (shown whenever any
  extension is loaded — an extension may have no toolbar action of its own). Per
  extension it shows the name, a ⚡ background-worker chip
  ("Persistent" vs "on demand"), and an "Access on all sites" toggle; a footer
  counts workers ("N of M run a background worker in this Space").
- **Host-access toggle — the 7.5c-finding fix.** WebKit does not prompt for a
  _required_ `host_permissions` extension, so the toggle calls
  `host.setAllHostsAccess(_:slug:in:)` →
  `context.setPermissionStatus(.grantedExplicitly/.deniedExplicitly, for:
WKWebExtension.MatchPattern.allHostsAndSchemes())`, persisting the grant (or
  dropping the extension's grants on off). `hasAllHostsAccess` reads
  `context.hasAccessToAllHosts`. This is the analogue of Safari's per-site
  toolbar menu, all-sites at once.
- **VERIFIED LIVE (2026-07-24)** with a required-`host_permissions` +
  service-worker dev extension (scaffold since reverted): the panel showed the
  ⚡ "Background worker (on demand)" chip and "1 of 1 run a background worker in
  this Space"; the banner was **inert** on load (no prompt for required host
  perms, as expected); toggling **Access on all sites** on then reloading
  **injected** the banner; the grant persisted (`devbanner | matchPattern |
*://*/*`). This closes the 7.5c finding end-to-end.
- **Tests:** +1 (`reportsBackgroundWorkerPresence` — a `service_worker` manifest
  reports `hasBackgroundContent`, a content-script-only one does not; against
  real WebKit). 277 total, prepush green.

### Phase 7.6 — soak with extensions across 3 Spaces (2026-07-24)

The §8/§6.6 gate for M7. Ran `scripts/soak.sh` (new `SOAK_URLS` override) with a
**mainstream-SPA** fixture — 3 Spaces / 21 tabs / 32 panes over Google, YouTube,
X, Instagram, Reddit, Wikipedia, GitHub, Amazon — and one extension (`soakext`:
content script + background worker + `<all_urls>`) **enabled in all three
Spaces**, so a per-Space background worker ran and content scripts injected on
the live pages. 30 minutes of Cmd+1…3 Space switching.

- **Pass, wide margins, no leak.** App process **55→64 MB then flat at 64 MB**
  for 20+ min (≪ 150 MB target). Total peaked ~747 MB as every SPA loaded at
  once, then WebKit eviction (§6.2) settled it to **~470–485 MB and held**
  (≪ 1.2 GB target). Idle CPU 0.63% (app, window visible) — under the 1% ceiling;
  the 0.5% target is a no-animation baseline the live SPAs don't represent.
- **The extension subsystem adds no measurable app-process cost.** Even with
  three per-Space workers, the end process inventory was 1 app + 5 WebKit helpers
  (1 networking / 3 WebContent / 1 GPU) — WebKit consolidates the workers rather
  than one-process-per-worker blowing up the count. Per-Space isolation did not
  multiply footprint.
- Numbers and method in [SMOKE.md](SMOKE.md) ("30-minute soak — M7"); samples in
  `/tmp/soak-220853.tsv`. Setup used a temporary `AppDelegate` DEBUG flag flip
  (reverted) plus pre-seeded `extensionEnablement`/`grantedPermission` rows; the
  real session was `.backup`'d and restored via `scripts/soak.sh restore`.
- **`SOAK_URLS` override added to `scripts/soak.sh`** so a heavier run needs no
  edit to the curated (cheap, not-ours-to-hammer) default list.

## M7 is complete — ready for review

All of M7 (7.1–7.6) has landed on `main` behind `FeatureFlags.extensionsEnabled`
(default **off**), so the shipping browser is unchanged until the flag is
flipped. Everything is verified live, `./scripts/prepush.sh` is green (277
tests), schema is v5, and the §6.1 budgets pass with the extension soak. This is
the M7 stop point (§8: stop after each milestone and wait for review).

**Owed / carried into the review, none blocking:**

- Instruments Allocations/Leaks pass (§6.7) — never run, same as M1/M3/M6.
- `optional_host_permissions` is the only path that triggers WebKit's runtime
  permission prompt; required `host_permissions` needs the 7.5d "Access on all
  sites" toggle. Both work; noted so a future extension-management UI keeps the
  toggle prominent.
- No extension-management surface beyond the header (install/remove is
  `ExtensionsService`-only, no UI); fine for personal use, a candidate follow-up.

## How content blocking works (so far)

### Milestone plan (§4.8, agreed 2026-07-25)

Native content blocking via `WKContentRuleList` — its own milestone (deferred out
of M7). Phases, one commit each: **C1** pure ABP→JSON converter · **C2**
`ContentBlocker` compile/cache/attach off-main + bundled seed list · **C3** weekly
refresh + fetch · **C4** soak/measure, then review. Flag-gated
(`FeatureFlags.contentBlockingEnabled`, added in C2, default off).

**The spec item is infeasible as literally written, and the plan says so.** §4.8
says "compile EasyList + EasyPrivacy into `WKContentRuleList`", but
`compileContentRuleList` takes **Apple's content-blocker JSON**
(`[{trigger,action}]`), not ABP filter syntax — so there is a conversion step,
and `WKContentRuleList` cannot express all of ABP (no scriptlets, limited
cosmetics, ~150k-rule cap that EasyList+EasyPrivacy exceed). v1 is a deliberate
**subset**. Decision (user, 2026-07-25): an **in-house Swift converter**, not a
bundled pre-converted list or a third-party Safari-format feed — it keeps the
logic pure/testable in Core, adds no dependency, and the weekly refresh just
re-runs our own code over the real lists (fits §2/§3.6 and the solo-tool mandate).

### Phase C1 — pure ABP→JSON converter (2026-07-25)

- **`ContentBlockRule`** (Core) is the `Encodable` model of one Apple rule —
  `trigger` (`url-filter`, `if/unless-domain`, `resource-type`, `load-type`,
  `url-filter-is-case-sensitive`) + `action` (`block` / `ignore-previous-rules`
  / `css-display-none`), with hyphenated `CodingKeys`. `[ContentBlockRule]
.contentRuleListJSON()` serialises with `.withoutEscapingSlashes`.
- **`ContentBlockConverter`** (Core, Foundation-only) turns a filter list into
  rules + counts (`parsedLines`, `skipped`). Supports: network rules (`||host^`,
  `|`/`|` anchors, `*`, `^`, substrings), exceptions (`@@` →
  `ignore-previous-rules`), options (`$third-party`/`~third-party`/`first-party`
  → `load-type`; `$domain=a|~b` → `if/unless-domain` with a `*` subdomain
  prefix; resource types via a map; `$match-case`), and element hiding
  (`##`/`###`, domain-scoped) → `css-display-none`. Standard **`:has()` is
  KEPT** — WebKit's selector engine compiles and hides it (verified end-to-end
  against `WKContentRuleListStore` + a live `WKWebView`: `div:has(> a.ad)` →
  `display:none`, control stays `block`). Recovers ~595 container-hiding rules
  from EasyList alone. **Drops and counts** regex literals, scriptlets, cosmetic
  exceptions/extended markers (`#%#`/`#$#`/`#?#`/`#@#`), and _proprietary
  procedural_ cosmetics only (`:-abp-`, `:upward`, `:xpath`, `:has-text`,
  `:matches-css`, …), negated resource types, and any unmapped modifier
  (`redirect`, `csp`, `removeparam`, …) — dropping beats blocking wrong. An
  unsupported `##` selector is now dropped outright, never re-parsed as a network
  URL (`convertLine` routes every `##` line through the cosmetic path only).
- **VERIFIED the JSON compiles in real WebKit** (throwaway
  `WKContentRuleListStore.default().compileContentRuleList`, since removed).
  This caught a real bug: **Apple's `url-filter` engine rejects disjunctions** —
  the natural `^`-separator translation `(?:[^…]|$)` failed with "Disjunctions
  are not supported yet." Fixed to the character class alone (`[^a-zA-Z0-9_.%-]`);
  a resource URL's trailing `/`/`:`/`?` satisfies it. Also learned for C2: the
  compile completion handler runs on the **main queue**, so a semaphore-blocked
  main thread deadlocks — C2's off-main compile must use async/await or a
  non-main wait.
- **14 tests** (url-filter translation, network/exception/options/resource-type
  mapping, element hiding, dropped-rule table, JSON shape + round-trip). 291
  total, prepush green. No WebKit imported by C1 — the whole converter is pure.

### Phase C2 — ContentBlocker compile/cache/attach (2026-07-25)

- **`ContentBlocker`** (BrowserEngine, WebKit-importing) owns a
  `WKContentRuleListStore` and the compiled `WKContentRuleList`, which never
  leaves the engine. `prepare()` looks the list up by identifier (the store is
  the on-disk cache — §6.6's "never compile on window open"); only when it is
  absent does it read the seed, run C1's `ContentBlockConverter`, and
  `compileContentRuleList`. **Compilation runs off-main inside WebKit** via
  `await` — no main-thread block, so no deadlock (the C1 finding).
- **`WebKitEngine.applyContentRuleList(_:)`** stores the compiled list and adds
  it to each view's `WKUserContentController` — both in `makeWebView` for new
  views and, crucially, **retrofitted onto already-live views**, because the
  first-launch compile finishes after the first views exist (they would browse
  unblocked until reloaded otherwise). `nil` clears via
  `removeAllContentRuleLists`.
- **Bundled seed list** (`Resources/seed-blocklist.txt`, a curated
  EasyList/EasyPrivacy subset — major ad/tracker networks) so blocking works on
  first launch offline; C3 replaces it with the full fetched lists. Loaded via
  `Bundle.module` (added `resources: [.process(...)]` to the BrowserEngine SPM
  target). `bundledSeedList()` is `nonisolated` so it can be the default provider.
- **Flag-gated:** `FeatureFlags.contentBlockingEnabled` (default off). With it
  off, `AppEnvironment` builds no blocker and attaches nothing — the engine is
  exactly what it was. On, it builds the blocker and, in a `Task`, compiles then
  `engine.applyContentRuleList(await blocker.prepare())`. The blocker is retained
  on `AppEnvironment`.
- **Verified against real WebKit** (4 tests, temp on-disk stores so the app's
  real cache is untouched): the **bundled seed converts + compiles**; a second
  `prepare()` returns the list **from cache even when the seed would fail**;
  inline rules compile; a comments-only seed compiles to an empty list without
  trapping. 295 total, prepush green (app build bundles the resource).
- **NOT yet driven live** — the decisive "a real ad/tracker request is actually
  blocked" check is folded into **C4**, which runs ad-heavy mainstream sites with
  the flag on and screenshots the effect; that run also confirms `Bundle.module`
  resolves the seed in the packaged app (a graceful nil-and-log if not).

**Known flake (pre-existing, not C2):** `ExtensionArchiveTests
.reinstallOverwritesInPlace` failed once under full parallel `swift test`
("not a recognised extension archive") and passed in isolation and on retry —
a test-isolation race in the installer's temp-dir handling, worth a fixture
fix sometime.

### Phase C3 — weekly refresh + fetch (2026-07-25)

- **`ContentBlockRefresh.isDue`** (Core, pure) is the schedule: due when never
  refreshed or a week elapsed. Unit-tested without a clock.
- **`ContentBlocker.refreshIfDue()`** fetches EasyList + EasyPrivacy
  (`network.client` is already entitled), converts, compiles under a
  **content-hashed identifier** (`blocklist-<sha256 prefix>`), swaps it in, and
  records the date in `UserDefaults`. The hash makes an unchanged list a cache
  hit; old `blocklist-` identifiers are pruned from the store. A **fetch failure
  leaves the date untouched**, so it retries next launch rather than waiting a
  week. All of fetch / defaults / clock / list-URLs are injectable, so the logic
  is tested with canned lists — no live network in the suite.
- `AppEnvironment` runs seed→attach first (fast, offline), then
  `refreshIfDue()`→attach in the same `Task` (off-main). On first launch the
  refresh is immediately due, so the full lists load in the background shortly
  after the seed.
- **VERIFIED against the real lists** (throwaway test, since removed): EasyList
  (2.1 MB) + EasyPrivacy (1.5 MB) fetched and converted to **137,687 rules from
  138,632 lines — only 945 skipped, 99.3% coverage**. That is the payoff of the
  in-house converter: nearly the whole of both lists is expressible.
- **Bug the C2 test caught:** the C3 refactor extracted the compile into helpers
  and dropped `compiledList = list` from `prepare()`, so the public property went
  nil (the app still worked off the return value). Fixed; the surviving C2 test
  is why it surfaced.
- **The rule cap is load-bearing, learned the hard way.** A first pass compiled
  the full 137k-rule set at a 50k cap **inside a diagnostic that fetched and
  converted twice** and the process **aborted (signal 6)** — a hard,
  _uncatchable_ abort under transient memory pressure, not an `NSError`. Isolated
  compiles of 25k/40k/**50k all succeed** in ~1.3–1.4 s, and the real
  **single-pass `refreshIfDue()` flow at 50k is stable**. So the abort was the
  diagnostic's redundant double-work, not the compile — but it proves the app
  must **never** attempt the whole set: `maxRules = 50_000`, EasyList being
  roughly most-important-first. Chunking into several lists to capture the tail
  is a possible later enhancement; measure memory in C4 first.
- 6 new tests (3 refresh behaviour, 3 schedule). 301 total, prepush green.

### Phase C4 — soak + live verification (2026-07-25)

The §8/§4.8 gate. Ran the mainstream-SPA soak with `contentBlockingEnabled` on
(temporary scaffold, reverted).

- **Verified live, decisively (A/B).** Blocking **on**: navigating to a blocked
  tracker (`googletagmanager.com/gtm.js`) was stopped before the network — the
  page stayed on the previously loaded `example.com`. Blocking **off** (a rebuild
  with the flag reverted): the identical navigation reached the server (Google's
  own 404). `example.com` loaded fine with blocking on. So the attached list is
  enforced at runtime, and normal browsing is unaffected.
- **Soak: pass, no leak, no added steady-state cost.** App process
  **32→58–60 MB, flat** (≪ 150 MB); total peaked ~747 MB then settled to
  **~464–487 MB and held** (≪ 1.2 GB); idle CPU 0.56% (under the 1% ceiling).
  Within noise of the M7 soak — the compiled list is shared/immutable, so
  attaching it costs almost nothing.
- **Compile spike is transient and off-main (§6.6).** ~103 MB _during_ the
  launch-time full 50k-rule compile, released to **32 MB** once done; the window
  was interactive at t+3 s, so the compile never blocked launch.
- **`Bundle.module` resolves the seed in the packaged app** (blocking worked from
  first launch before the refresh landed), closing the C2 open question.
- Numbers/method in [SMOKE.md](SMOKE.md) ("30-minute soak — content blocking");
  samples in `/tmp/soak-052928.tsv`.

### Post-milestone — full-list chunking + a day-2 fix (2026-07-25)

An optional follow-up that both widened coverage and fixed a real bug found
while doing it.

- **Chunking.** The 50k cap dropped ~87k of the 137k rules. WebKit attaches
  several `WKContentRuleList`s to a view and matches across all of them, so the
  full converted set is now split into `maxRulesPerList` (50k) chunks and each
  compiled under `<base>-<index>`; the engine holds `[WKContentRuleList]` and
  `applyContentRuleLists` attaches them all. Verified against the real lists:
  **all ~137k rules compile as 3 chunks in ~3.7 s**, off-main, no abort — so
  coverage went from the 50k head to the whole of EasyList + EasyPrivacy.
- **Bug fixed: blocking silently shrank to the seed between weekly refreshes.**
  C3 only attached the refresh result when a refresh was _due_; on any launch
  within the week `refreshIfDue()` returned nothing, so only the tiny bundled
  seed stayed attached and the full cached list was ignored. New `activeLists()`
  re-attaches the cached full set every launch (keyed by a persisted
  `currentIdentifier`), falling back to the seed only on the very first launch.
  A regression test (`reattachesCachedFullList`) covers it.
- API changes: `ContentBlocker.compiledList` → `compiledLists`, `prepare()` →
  `activeLists()`, both `refreshIfDue()` and `activeLists()` return
  `[WKContentRuleList]`; `WebKitEngine.applyContentRuleList` →
  `applyContentRuleLists([…])`. 302 tests, prepush green.

## Content blocking is complete — ready for review

C1–C4 have landed on `main` behind `FeatureFlags.contentBlockingEnabled`
(default **off**). Verified live, `./scripts/prepush.sh` green, and the §6.1
budgets pass with the blocker on. This is the milestone stop point (§8).

**Optional follow-ups (none blocking):**

- **Chunk the rule list to capture EasyList's tail.** The 50k cap keeps the
  high-value head (EasyList is roughly most-important-first); WebKit supports
  multiple attached lists, so several ≤50k lists would raise coverage. Measure
  memory first (the compile is the heavy part).
- **A settings toggle** for the flag, instead of the launch-time constant.
- **Whitelist / per-site disable** (an `ignore-previous-rules` rule keyed to the
  current host) — the machinery is already there.
- **Leaks pass (§6.7) — done 2026-07-25, clean.** `leaks <pid>` on the running
  app after browsing reported 282 leaks / 14 KB, **all macOS framework noise**
  (AppIntents / Shortcuts `linkd` XPC cycles that every app gets) — **none of our
  types, and none of §6.7's WebKit delegate/script-handler leaks**. Combined with
  the flat soak footprint (Allocations-growth proxy), the app is leak-clean. The
  full Instruments GUI trace (SwiftUI body counts, Energy Log) is not automatable
  here and remains the only untouched part.
- ~~Pre-existing `ExtensionArchiveTests.reinstallOverwritesInPlace` parallel
  flake.~~ **Fixed 2026-07-25:** `writeTemp` wrote sources to a fixed name in the
  shared temp dir, and three tests used `ext.xpi`; Swift Testing runs them in
  parallel, so one truncated the file while another read it ("not a recognised
  extension archive"). Each source now gets a unique directory. 5 consecutive
  full runs clean.

## Next steps, in order

**M7 is complete (7.1–7.6).** 7.3b and all of 7.5–7.6 are verified live (above).
This is the review stop point. After review: either flip `extensionsEnabled` on
for daily use, or start content blocking (§4.8), which was deferred to its own
later milestone.

### M7 phase 7.5 — action popover + permission UI (DONE, verified live 2026-07-24)

The original four-sub-phase plan is kept below for the record; all four shipped
(see the 7.5a–7.5d sections above), one commit each. Two design decisions made
2026-07-24 held up:

- **§6.6 memory: defer.** No WKWebExtension API exposes process/memory (checked
  every `WKWebExtension*.h` on the macOS 26.5 SDK). 7.5d surfaces _presence/count_
  of background-worker extensions per Space; real memory is a later follow-up —
  proc sampling is fragile/SPI-adjacent, do NOT reach for it.
- **Permission grants persist in a new SQLite table, schema v5.** Not left to
  WebKit's own persistence.

- **7.5a — WK-free action model + `didUpdateAction:` wiring.** New
  `ExtensionActionSnapshot` (WK-free: slug, spaceID, label, badgeText,
  `presentsPopup`, `enabled`, icon as PNG `Data?`). Host implements
  `webExtensionController(_:didUpdate:forExtensionContext:)`, maps
  `WKWebExtensionAction` → snapshot, caches per (Space, slug), fires a change
  observer the Store/UI reads. Extend `ExtensionHost` + `ExtensionsService` with
  `actions(in:)`. Default action via `context.action(for: nil)` / `action(for:)`.
- **7.5b — popover + sidebar-header buttons.** `WKWebExtensionAction.popupPopover`
  is a ready-made `NSPopover` (macOS) — host takes an anchor `NSView` from UI and
  calls `popover.show(relativeTo:of:preferredEdge:)`, keeping WebKit in the host
  (ADR 011). Implement delegate
  `webExtensionController(_:presentActionPopup:for:completionHandler:)` for
  extension-initiated popups. SwiftUI action buttons in the sidebar header, behind
  `extensionsEnabled`.
- **7.5c — permission-grant UI + schema v5 (load-bearing).** Content scripts stay
  inert until host permissions are granted. Implement the three delegate prompts:
  `promptForPermissionMatchPatterns` / `promptForPermissionToAccess` (URLs) /
  `promptForPermissions`. Surface a WK-free `PermissionRequest` to the Store → a
  SwiftUI grant/deny sheet; the completion handler returns the allowed set.
  Persist grants in a new `grantedPermissions` table (migration **v5**); on
  `load`, re-apply via `context.setPermissionStatus(.grantedExplicitly,
for: matchPattern)`. All permission API is `macos(15.4)` — clears our floor.
  Only Denied/Unknown/GrantedExplicitly may be _set_.
- **7.5d — per-Space background-worker presence (§6.6).** Count/flag extensions
  with a background worker per Space in the extensions UI. Memory deferred.

**Verified API (checked against the SDK headers 2026-07-24 — safe to use):**

- `WKWebExtensionAction`: `.popupPopover` (`NSPopover?`, macOS), `.popupWebView`,
  `.presentsPopup`, `.label`, `.badgeText`, `.isEnabled`, `iconForSize(_:)`
  (`NSImage?`), `closePopup()`.
- `WKWebExtensionContext`: `action(for:)`, `setPermissionStatus(_:for:)` (for
  permission / URL / matchPattern; `.grantedExplicitly`), `hasPermission(_:in:)`,
  `permissionStatus(for:in:)`.
- Delegate Swift names: `webExtensionController(_:didUpdate:forExtensionContext:)`,
  `webExtensionController(_:presentActionPopup:for:completionHandler:)`,
  `webExtensionController(_:promptForPermissions:in:for:completionHandler:)`,
  `webExtensionController(_:promptForPermissionToAccess:in:for:completionHandler:)`,
  `webExtensionController(_:promptForPermissionMatchPatterns:in:for:completionHandler:)`.

**Verifying 7.5 live (when ready):** add a temporary DEBUG hook in `AppDelegate`
to flip the flag on + load a dev extension (an unpacked MV3 dir works as
`resourceBaseURL`), grant all-hosts, open a **fresh** tab, screenshot. A
content-script banner appearing = injection works; absent in another Space =
per-Space isolation. Content scripts only inject on page load — a
restored/already-loaded page won't get them retroactively. Revert the scaffolding
after; `os.Logger` logs are NOT retrievable via `log show`/`log stream` on this
host, so `screencapture -x -o out.png` + Read the image is the reliable signal.

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
  which of three places a result belongs in. A plain blank tab is still one
  keystroke away — the escape hatch when you genuinely want one — though it moved
  from `Cmd+N` to **`Cmd+Shift+N`** when multi-window took `Cmd+N` for New Window
  (the platform's binding, and Arc's).
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
- ~~Open for 7.4: how per-Space enablement is stored — an enablement table vs
  per-Space prefs.~~ Resolved: SQLite table, migration `v4_extension_enablement`
  (it is behaviour-affecting user state, so it earns §7.2's discipline).
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

### Pinned tabs — the third tier (post-M7, 2026-07-26)

Arc's three tab tiers, finally all present (§4.1a):

- The existing `TabPlacement.pinned` is **Favourites** (the icon grid) — the name
  predates Arc's "Pinned" and was too costly to rename across ~90 sites, so the
  new tier is `.bookmarked` in code and "Pinned" in the UI. `isBookmarked`,
  `isEphemeral`, and `homeURL` were added; `isPinned` still means Favourites
  only. If this naming bites, that is why.
- **Both** non-ephemeral tiers now carry a `homeURL`. It is optional on `.pinned`
  so favourites made before this change decode as "no home" rather than being
  dropped — the `pinnedHomeURL` column (migration **v8**, additive, nullable)
  backs both tiers, and `TabMapping` writes `placement.homeURL` for whichever has
  one. A `.bookmarked` row that decodes with no recoverable URL is demoted to
  `.ephemeral`, never dropped.
- The sweep now exempts on `!isEphemeral`, not `isPinned` — otherwise Pinned tabs
  would be swept. One-line change in `SweepPolicy`, easy to miss.
- **Close keeps the entry** (`unloadTab`): a favourite or Pinned tab is unloaded,
  not removed. A favourite's state is captured first (reopen restores it); a
  Pinned tab is reset to `homeURL` by **replacing its pane with a fresh one** —
  the new pane id orphans the stale interaction blob (pruned on next save), which
  is what actually clears the drifted back/forward history so it lands on home
  rather than restoring the drifted page. The favicon is carried onto the reset
  pane **only when host matches** the home origin (favicons are per-origin).
- Return-to-home: double-click a favourite tile (`TabDragSource` gained an
  `onDoubleClick`; the tile click path is AppKit, so a SwiftUI `.onTapGesture`
  would not fire), or click an already-selected Pinned row.
- `reorderTab` was generalised from a `toPinned: Bool` to a three-way
  `PlacementSection`; the old boolean call is a back-compat wrapper so existing
  tests and the favourites/ephemeral drag are unchanged.
- The Pinned section header collapses the list. State is **per-Space**, in
  `collapsedPinnedSpaces` (a `Set<UUID>` in `UserDefaults`, like the sidebar
  width) — not the schema. `addSpace` makes the new Space active, which the first
  collapse test got wrong; select the Space you mean before toggling.

### `WindowState` — window state split out of `TabStore` (2026-07-27)

Step 1 of making a second browser window possible. **No behaviour change**: still
one `Window`, still one of everything. What moved is *ownership*.

- **The dividing line is ownership, not layer.** `TabStore` owns the world —
  tabs, Spaces, folders, persistence, the sweep — and every window shows the same
  one. `WindowState` owns how a window is *looking* at it: sidebar collapse and
  width, `collapsedPinnedSpaces`, and the four sheet flags (`editingSpaceID`,
  `deletingSpaceID`, `isSettingsPresented`, `isHistoryPresented`).
- **Checked against Arc first, rather than guessed.** Two Arc windows share one
  Space *list* (a Space made in one appears in the other) but each has its own
  active Space, its own sidebar, and Cmd+1…9 switches only the focused window.
  So the Space collection is session-level and selection is window-level. That
  is why `WindowState` is thin and `TabStore` keeps the repository wiring.
- **Selection did NOT move**, deliberately. `selectedTabID` / `activeSpaceID` are
  maintained as invariants by the store's own mutations (`closeTab`, the sweep,
  `closePane`, `moveTab`), and moving them needs a reconciliation rule for what
  window B does when window A closes the tab B was showing. Separate change.
- **`isPinnedSectionCollapsed` took a parameter** — `(inSpace:)` — because the
  active Space still lives on the store. It loses the parameter again when
  selection moves.
- **Menu commands now use `@FocusedValue`, not `NSApp.mainWindow`.** Settings,
  Toggle Sidebar, and Show History used to ask AppKit which window was "main",
  which is a guess that is only right while there is one. `FocusedWindowState`
  carries the focused window's state to `Commands`, which is built once for the
  whole app and so cannot capture a particular window. Not a §3.6 violation — no
  *service* travels through the environment, only scene-scoped view state.
- **The `UserDefaults` keys are unchanged** (`sidebar.collapsed`, `sidebar.width`,
  `prefs.collapsedPinnedSpaces`), so an existing profile does not reset. The two
  sidebar keys moved into `Preferences` but kept their unprefixed names.
- **A new window seeds from the persisted values, then owns its copy.** Windows
  have no durable identity to key on until layout persistence exists (that would
  be v9), and inheriting is what Arc appears to do.
- **`RootView.body` had to be split.** Adding one modifier tipped it past what
  the type-checker would solve in reasonable time — the error points at whatever
  line it gave up on (`swipeMonitor = nil`), not at the cause. The five sheets
  moved to a `RootSheets` ViewModifier. Worth knowing that body was already at
  the limit before this change.
- **Verification.** 373 tests pass (371 + 2 new: collapse is per-window, and a
  new window inherits the sidebar then diverges). `prepush.sh` green. Then
  against the real app, because none of the above proves the `@FocusedValue`
  wiring: Cmd+S, Cmd+Y, Cmd+, all fire, History's Done dismisses, and
  `sidebar.collapsed` wrote through to the container plist. Note AppleScript
  reports `enabled` as false for a menu item until its menu has been opened
  once — query it after clicking the menu, or you will chase a phantom.
- **Tests do not touch `UserDefaults` at all**, via a two-method
  `PreferenceStore` protocol (`UserDefaults` conforms as-is) and an
  `InMemoryPreferenceStore`. The first attempt — `UserDefaults(suiteName:)` per
  test — is a trap worth recording: registering a suite creates a *persistent*
  domain, and `cfprefsd` recreates the plist at process exit no matter how
  carefully you call `removePersistentDomain` and `synchronize` first. It left
  three `chord.tests.*` files in `~/Library/Preferences` per run. Only not
  registering a domain in the first place actually works.
- The old `PinnedTests` collapse test was writing to the **real** `UserDefaults`,
  which is how the leak was noticed at all.

### Multiple windows (2026-07-27)

`Window` → `WindowGroup`. Cmd+N opens a real second window; each has its own
Space, selection, sidebar, and find bar, over one shared store.

**The model checked against Arc first, not guessed.** Two Arc windows share one
Space *list* — a Space made in one appears in the other — but each has its own
active Space, its own sidebar collapse/width, and Cmd+1…9 moves only the focused
window. Dragging a tab between windows warns "you might get logged out", i.e. it
is a Space change, not a window primitive. So:

- `TabStore` owns the world: tabs, Spaces, folders, persistence, the sweep.
- `WindowState` owns the view onto it: `activeSpaceID`, `selectedTabID`, sidebar,
  sheets, find, swipe progress.

**Selection reconciliation — the rule worth remembering.** The window performing
a mutation fixes its own selection *with intent* (closing tab 3 selects tab 4).
Every other window has no intent to honour and only needs to stop pointing at
something gone, which `reconcileWindows(excluding:)` does after the mutations
that *remove* things. Adding never invalidates a selection and does not call it.

- `isSelectedByAnyWindow` is what keeps the **sweep** honest: a tab on screen in
  window B is not idle however long ago window A last touched it. Without this
  the sweep archives a page the user is reading. Covered by a test.
- `unloadTab` bails out when another window still shows the tab — tearing the
  view down would blank *that* window.
- `select` no longer captures interaction state for the outgoing tab when another
  window still shows it; the pane is still live there.

**Migration shape.** `TabStore` keeps `primaryWindow` and proxies the old
no-argument API (`selectedTabID`, `activeSpace`, `visibleTabs`, …) onto it, so
~150 existing test call sites and every "the one window there is" caller stayed
untouched. The window-scoped forms take `in window: WindowState? = nil`
defaulting to the primary. **These proxies are scaffolding, not the design** — new
code should pass the window explicitly, and the proxies should go once nothing
outside tests uses them.

- `claimWindow()` is how a scene gets its state: the primary for the first
  window, a fresh registered one after. `WindowGroup` builds content for every
  window and gives no say in which is first, so the scene asks rather than
  decides. Held in the scene's `@State` so it is stable for the window's life.
- Windows are held **weakly** (`WeakWindow`) — a window belongs to its scene, and
  a closed one must not be kept alive by the store's list.
- **`restore()` is a session concern**: only the scene holding the primary calls
  it. The `hasRestored` guard still exists, but a second window should not be
  asking — that exact ambiguity is what kept this app on a single `Window`.
- The command bar panel is built once and reused, so it cannot store a window.
  `CommandBarTarget` is a small observable box set on every presentation;
  without it a bar opened from window 2 opened tabs in window 1.
- Menu commands moved off `NSApp.mainWindow` to `@FocusedValue`, and `NSApp
  .mainWindow` → `NSApp.keyWindow` for panel parenting.
- **Cmd+N is now New Window** (Arc's binding, and the platform's). "New Blank
  Tab" moved to Cmd+Shift+N. It was only ever on Cmd+N because there was no
  window to open.
- `RootView.body` blew the type-checker budget *again*; the three sidebar-hold
  `onChange`s collapsed into one `isSidebarHeldOpen`. Same rule three times, so
  this is smaller and clearer as well as compilable. If you add a modifier to
  that body and get an error pointing at an unrelated line, this is why.

**Verification.** 381 tests (373 + 8, seven of them multi-window: distinct claims,
different Spaces at once, per-window Cmd+1…9, per-window new tab, close
re-pointing another window, sweep skipping a tab visible elsewhere, Space delete
re-homing, per-window find). `prepush.sh` green. Against the real app: File ▸ New
Window produces a genuine second window (2 on-screen windows via
`CGWindowListCopyWindowInfo`), and both menu items carry the right key
equivalents (⌘N / ⌘⇧N read back from `AXMenuItemCmdChar`).

**Not verified, worth a manual minute:** the ⌘N *keystroke* end-to-end — the menu
item works and the key equivalent is registered, but a synthetic AppleScript
keystroke did not fire it (⌘S/⌘Y do, so it may be `openWindow` and synthetic
events). Also unverified visually: that the second window paints its content
rather than the `Color.clear` shown while `claimWindow()` resolves — clicking
into it does hit a real element, but no screenshot was taken. Note
`System Events`' `every window` reports **0** for this app while CoreGraphics
reports the real count; use the latter, and `AXFocusedWindow` for the former.

### Proxies deleted — the window is now required (2026-07-27)

The `primaryWindow`-backed conveniences on `TabStore` are gone from the shipping
targets. `in window: WindowState` has no default any more, so "which window did
you mean" is a compile error rather than a silent answer.

- **The scaffolding moved to `BrowserTestSupport`**
  (`TabStore+SingleWindow.swift`), which only the *test* targets link. A headless
  test genuinely has one window, so `store.selectedTab` stays readable there;
  the same expression in `BrowserUI` or the app does not compile. All 381 tests
  needed **zero** edits. `BrowserTestSupport` gained a `BrowserStore`
  dependency — no cycle, because nothing in `Sources` links it.
- **Verify the enforcement with a concrete type, not `Any`.** A first probe of
  `-> Any? { s.selectedTab }` compiled and looked like a leak — it was binding
  the *unapplied method* `(WindowState) -> Tab?`. Only `-> BrowserCore.Tab?`
  proved the property is genuinely invisible.
- **Removing the properties was not enough**, which the probe also caught:
  `closeTab(id)` still compiled because the `in window:` *defaults* were still
  there. Both had to go.
- Sites that legitimately have no originating window now say so out loud rather
  than defaulting: `restore()` and `application(_:open:)` and Little Arc's
  promote/surface all name `primaryWindow` with the reason. Little Arc promoting
  into the primary while a second window is focused is a **known limitation**,
  commented at the call site.
- Two `WindowState? = nil` remain and are correct:
  `reconcileWindows(excluding:)` (nil = no acting window, i.e. the sweep) and
  `TabStore.init(primaryWindow:)` (nil = make one).
- Engine callbacks now carry their origin: `paneRequestedNewTab` gained
  `fromPane:`, so `window.open()` opens its tab in the window showing the page
  that called it rather than the first one. `extensionActiveTab(inSpace:)` and
  the extension activate/close paths resolve through `window(inSpace:)`.
- Menu actions funnel through one `withFocusedWindow` helper, so the focused-
  window question is answered in a single place.

### `prepush.sh` was reporting OK on a failed app build

Found while running the above. The app step was
`xcodebuild ... | grep -E "error:|warning:|BUILD" || true`: under `set -e` the
pipeline's status is *grep's*, and `|| true` discarded even that, so a failing
`xcodebuild` still fell through to `echo "==> OK"`. The package and test steps
were always fine — only the app build was unguarded, and it is the step most
likely to break on its own (project file, entitlements, Xcode version).

Now it captures to a temp log and propagates xcodebuild's own status. Verified in
both directions: a deliberate syntax error in `AppDelegate.swift` exits 1, and a
clean tree exits 0. Worth knowing if you ever trusted a green prepush that
predates this.

### Cross-window tab drag (2026-07-27)

The gesture itself needed no new plumbing: the drag is already AppKit
(`TabDragSource` writes a real `NSPasteboardItem`, `SidebarDropTarget` reads it),
and an `NSDraggingSession` crosses windows within an app for free. `draggingTabID`
lives on the store, so the destination window shows its drop targets while a drag
started in another window is in flight.

What was missing was the *model* side.

- **A drop is no longer "within this tab's own Space".** `reorderTab` reads
  `moving.spaceID`, so a tab dropped into a window showing a different Space
  renumbered itself invisibly in the Space it came from — a silent no-op from the
  user's side. The sidebar now calls `dropTab(_:into:at:in:)`, which compares the
  tab's Space against the *destination window's*.
- **Crossing Spaces is a profile change, so it asks first.** Each Space has its
  own `WKWebsiteDataStore`; the page is rebuilt against different cookies and a
  signed-in session does not survive. `PendingTabMove` on the destination
  `WindowState` puts the dialog up; Arc prompts for the same reason and says the
  same thing.
- **Same Space, two windows** shows the same list in both, so a drop between them
  is an ordinary reorder plus selecting what was dragged. No prompt.

**The hole this closed was one multi-window opened.** Dragging into another
window's *content area* (drag-to-split, 4.5) was previously unreachable across
Spaces — one window meant the sidebar only ever showed one Space, so no drag
could carry a tab across one. With two windows it can, and
`split(_:byMoving:)` would have closed the source tab and rebuilt its URL as a
pane in the target's Space, changing the data store with no warning at all. It
now routes through the same prompt, hence `PendingTabMove.Destination`
(`.section` vs `.splitInto`) rather than a bare section + index.

**Deliberately left alone:** dragging a tab onto a *Space button* in the switcher
still moves it with no prompt. Same hazard, but it is a targeted gesture onto a
Space the user named, it predates this change, and adding a dialog there is a
behaviour change to an existing feature rather than part of this one. Worth
revisiting if the inconsistency grates.

Nine new tests: same-Space reorder without prompt, cross-Space prompt-then-move,
confirm, cancel, section preserved across the move, and the four split-drop
cases. 390 total, `prepush.sh` green.

### Blank-window bug, found by manual testing (2026-07-27)

Driving the multi-window smoke checklist with `cliclick` turned up two of three
windows rendering **blank** — empty content area, working sidebar, no crash and
no log. `WindowState`'s own doc comment had it backwards: a `WKWebView` is an
`NSView` with exactly **one** superview, so a tab selected in two windows shows
in whichever drew last and leaves the other empty. A tab is on screen in at most
one window; the model has to guarantee it.

Three defects fed it, all in selection assignment, all fixed in
`fix: one tab is shown in at most one window`:

1. `restore()` never reconciled the other windows. macOS restores a second scene
   at launch, which calls `claimWindow()` *before* the async restore has loaded
   any Spaces — so it held nil/nil and nothing ever fixed it.
2. `reconcile` read its Space through `?? spaces.first` without writing it back,
   and `nil` slipped past the "is my Space valid" check — which is why the
   restored window stayed unrepaired.
3. Every selection-assigning path could pick a tab another window already had.
   `claimWindow` adopted the primary's tab outright.

Now: `claimWindow` reconciles rather than adopting, `reconcile` prefers a tab no
other window holds and opens a fresh one when none is free, and `select` hands a
contested tab over and re-points the window that lost it. Invariant:
`windowShowing(_:excluding:)` is nil for every window's own selection.

The DEBUG overlay (⌃⌘P) now shows, per window, its identity / Space / selection /
**`also showing it`**. That last count made this diagnosable and must stay **0** —
screenshots could not, because windows shuffle z-order between captures and a
blank window is indistinguishable from an unloaded one.

### Current state — where multi-window stands

Milestones M1–M7 are done (see earlier entries). Multi-window is functional and
manually verified through the checklist's §A–§D:

- **Verified working:** ⌘N (keystroke included), second-window rendering,
  per-window sidebar / Space / find independence, cross-window tab drag with the
  cross-Space profile prompt (confirm + cancel), the split-drop variant of that
  prompt, and ⌘Y routing to the focused window.
- **Re-run after the blank-window fix (2026-07-27):** the §D ⌘D / ⌘⇧D menu
  items and SMOKE §E now pass in the live app. ⌘D/⌘⇧D act on the focused
  window's selection and leave the other window's selection alone. §E: closing
  the second window leaves the first working; quit+relaunch brings both windows
  back **painting** (the blank-window bug's exact scenario) with `also showing
  it 0` in each; deleting the Space a window sits in re-homes it to a surviving
  Space instead of blanking. Per-Space login isolation holds with two windows
  visible at once (same site, one logged in, one signed out).
- **Still unverified in the live app:** the two-*distinct*-Google-accounts form
  of the isolation check (needs a second real sign-in — credentials) and the
  extensions-under-two-windows check (this profile has **no** extensions
  installed — `extensionEnablement` empty, no manifests — so there is nothing to
  load; install one first). Both are unit-tested.

**Known gaps and deferrals**, in rough priority. **Read the next section before
acting on any of these — #1–#5 were all closed by the batch that follows;** the
list is kept because it is what the batch was aimed at.

1. **Empty area below the tab list is not a drop target** — a drop there is
   silently ignored, which reads as a broken drag. Most browsers accept a drop
   anywhere in the list. Small papercut, worth closing.
2. **Little Arc and app-opened URLs land in the primary window**, never the
   focused one — the panel does not track a window. Commented at the call sites.
3. **Dragging a tab onto a Space button does not prompt** on a cross-Space move,
   unlike every other cross-Space drag. Inconsistent; deliberately left.
4. **Window layout is not persisted** (which Space/tab each window had). macOS
   restores the *scenes*, but each comes back reconciled to a default selection.
   Real persistence would be a v9 migration.
5. **`SMOKE.md` note corrected**: relaunch restores *two* windows via macOS scene
   restoration, not one — Chord persists no layout of its own. Earlier entries
   here that imply single-window-on-relaunch are stale.

### Post-multi-window feature batch (2026-07-27)

Six items off the multi-window backlog, in one session. All packages build with
warnings-as-errors, the app builds, and `./scripts/prepush.sh` is green (407
tests). Not yet committed.

- **#2 Sidebar drop-target papercut** — a drop in the empty area below the tab
  list was silently ignored. `ephemeralList` (a greedy `ScrollView`) split the
  leftover height with a trailing `Spacer`, leaving that gap outside the
  overlaid `SidebarDropTarget`. The ScrollView now fills the region
  (`.frame(maxHeight: .infinity)`, Spacer removed) so the drop target covers it;
  `insertionIndex(forY:)` already clamps to the end, so a drop there appends.

- **#3 Little Arc / app-opened URLs → focused window** — the store now tracks
  the last-focused `WindowState` (`focusedWindow` / `windowDidBecomeFocused`,
  fed by RootView on `didBecomeKey`); `WindowRegistry` (BrowserUI) maps a
  `WindowState` to its `NSWindow` for bring-forward. `LittleArcController.promote`
  and `AppDelegate.application(_:open:)` target `focusedWindow`, not the primary.
  Tested in `MultiWindowTests` (tracks last-focused; weak fallback to primary).

- **#4 Space-button cross-Space drag prompts** — dropping a tab on a Space button
  went straight to `moveTab` with no confirm. New `PendingTabMove.Destination`
  case `.space` + `dropTab(_:ontoSpace:in:)` routes it through the same prompt as
  the sidebar/split paths (own-Space drop is a no-op). Tested.

- **#5 Window layout persistence (v9)** — new `windowLayout` table (ordinal,
  activeSpaceId, selectedTabId), `WindowLayout` model, `WindowLayoutRepository`
  + `SQLiteWindowLayoutRepository`. Restore applies layouts to already-registered
  windows in order and queues the rest; `claimWindow` pops the queue for scenes
  that claim after restore; both paths guard the one-tab-one-window invariant
  (`applyLayout` falls back to `reconcile` on a contested/stale tab or missing
  Space). Saved via the debounced `performSave`; `selectSpace`/open/close now
  schedule a save. Migration fixture test + restore tests. Schema is now **v9**.

- **#7 Camera + microphone** — `NavigationCoordinator` implements
  `requestMediaCapturePermissionForOrigin…` returning `.grant`; entitlements
  gain `device.camera`/`device.microphone` and Info.plist gains
  `NSCamera/NSMicrophoneUsageDescription`. Meet's camera/mic now reach the OS TCC
  prompt. **Screen sharing is infeasible**: `WKMediaCaptureType` has only
  camera/microphone and public WKWebView exposes no display-capture hook
  (verified against WKUIDelegate.h) — "Present now" cannot be supported without
  private API. Not faked.

- **#6 Web notifications** — public WKWebView has no notification hook, so
  `NotificationBridge` shims `window.Notification` and bridges over message
  handlers (show = plain handler; `requestPermission` = with-reply handler) to
  `NotificationController` (app layer), which posts via `UNUserNotificationCenter`
  and routes a click back to focus the tab and fire the page's `onclick`
  (`TabStore.handleNotificationClick`). This is notifications while the app is
  running and the page is open — **not** background Web Push (that needs
  Safari-gated APNs). Needs the user's macOS notification permission at runtime.

**Live-verification gaps** (need OS-permission grants only the user can give, so
left to the operator): #6 notifications end-to-end (grant notification
permission, observe a banner + click routing) and #7 camera/mic on a real site
(Google Meet). The app launches cleanly with the new per-web-view script/handler
registration and media delegate — the regression that mattered.

**Xcode project note:** `NotificationController.swift` was added to
`Browser.xcodeproj/project.pbxproj` (the app target lists files explicitly — not
a synchronized group — so a new file must be referenced there to build). The
repo's git rule excludes the pbxproj from commits; this addition needs to ride
along (or be re-added in Xcode) or the app target won't compile the file.

### Site permissions, notifications, UA, and media (2026-07-27 → 2026-07-31)

Everything below shipped after the multi-window batch and was **not** in this
file until 2026-07-31, when the docs were brought back in step with `main`. Order
follows the commits.

- **Web notifications (`d58787a`, `a161b42`, `084fd84`) — ADR 015.** Public
  `WKWebView` has no notification hook (checked against `WKUIDelegate.h`), so
  `NotificationBridge` shims `window.Notification` at document start in all
  frames and bridges to `NotificationController` →
  `UNUserNotificationCenter`; a click routes back through
  `TabStore.handleNotificationClick` to focus the tab and fire the page's
  `onclick`. Two handlers, deliberately different: `chordNotifyShow` is one-way,
  `chordNotifyPermission` is **with-reply** (the page is awaiting an answer) and
  carries an `op` — `query` reads the remembered decision without prompting,
  `request` may prompt. **Not Web Push**: the page must be open. The first cut
  seeded permission from the OS grant, which is app-wide — Slack re-asked on
  every visit and one grant spoke for every site; that is what the per-site model
  below replaced.
- **Per-site camera/mic/notification permissions (`9270bcc`, `084fd84`) — ADR
  014, schema v10 → v11.** The previous behaviour was a blanket `.grant` in
  `NavigationCoordinator` — every site could open the camera unasked. Now one
  model covers all three kinds: `SitePermissionKind` / `SitePermissionPrompt` /
  `SitePermissionRecord` in `BrowserCore` (WebKit-free), suspended requests
  resolved through `TabStore.requestSitePermission` / `resolveSitePermission` and
  a single `SitePermissionSheet`, decisions keyed on **(Space, origin, kind)**.
  `v10_site_permissions` adds the table; `v11_site_permissions_per_space`
  re-scopes it, adopting existing rows into the first Space rather than dropping
  them (same shape as v6 — §7.2 forbids deleting user data in a migration).
  Settings → Privacy & Data lists and revokes them. Verified live: Google Meet
  prompted once, granted, joined; relaunch joined with no prompt.
- **Microphone in Release (`0fe71b7`).** Worth remembering, because the shape
  recurs: **Hardened Runtime and App Sandbox use different keys for the mic.**
  Release (Hardened Runtime on) needs `com.apple.security.device.audio-input`;
  the sandbox key is `com.apple.security.device.microphone`. Camera shares one
  key across both, so camera worked while mic did not, and **Debug hid it
  entirely** — ad-hoc signing disables Hardened Runtime, so only the sandbox key
  was consulted. Both are declared now. Neither `swift test` (unsandboxed) nor a
  Debug build can catch this class of bug; only a production build can.
- **User-Agent setting (`f5e05b7`, `ef38189`).** Settings → General: Default /
  Chrome / Firefox / Safari-iPhone / Custom, the custom field pre-filled with the
  current UA so it is edited rather than invented. Global and applied on the next
  load; the §9.6 per-domain override map is still not built. Related, and already
  a memory the user hit twice: **Google Meet breaks under the Firefox UA**
  ("Couldn't start video call") — that is UA sniffing, not permissions.
- **YouTube ad skipping (`2620f4e`, `ec24bee`) — ADR 013.** A page-side script,
  not the content blocker, which cannot reach first-party video ads. Skips when a
  Skip button exists, and for unskippable ads both seeks to the end **and** runs
  playback at 10× — the seek alone does not work, because the ad module runs its
  own timer off media playback rather than `currentTime`. Rate is restored to 1×
  on the first non-ad tick and on `ended`, since ad and content share one
  `<video>`.
- **Rename + version (`8d07cae`, `e7f0a2e`).** `PRODUCT_NAME`/marketing version
  set for the Chord identity; bundle id deliberately unchanged (see
  `docs/branding/BRANDING.md` — it keys the on-disk profile).
- **Per-codec decode diagnostics (`c41cc9a`)** — see the AV1 note near the top of
  this file. `WebEngine.codecSupport` → `TabStore+Diagnostics` → the `Cmd+Ctrl+P`
  overlay, DEBUG-only.
- **`managedMediaSourceEnabled` (`2108474`).** One line in
  `WebKitEngine.makeConfigurationTemplate`, set on `config.preferences` **by KVC
  string key**. There is no typed accessor in any SDK header, which makes it the
  single place the project reaches past §11's "never invent WebKit API". Flagged
  rather than buried: if WebKit ever removes the key, KVC raises
  `NSUnknownKeyException` while building the configuration template — i.e. it
  would present as a crash at first web view, and no test covers it, because
  `swift test` never builds this template. If the app starts dying on launch
  after an OS update, suspect this line first.

**Verification gaps carried out of this batch** (all need a human, not a test):
notifications end-to-end after an OS permission grant was confirmed on
`bennish.net`; the two-*distinct*-Google-accounts form of the isolation check and
the extensions-under-two-windows check remain unrun (no second credential set, no
extensions installed in this profile). No soak has been re-run since the content
blocking one (2026-07-25) — the batch added per-view scripts (notifications) and
a permission path, so a fresh 30-minute soak is the honest next measurement if
anyone wants the §6.1 gate to still mean something.
