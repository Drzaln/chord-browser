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
| **Next**                         | **Nothing assigned. The password vault is complete — V1–V7 all shipped and verified live** (V7, the lock, on 2026-07-31); this is a review stop point. Known cost, accepted: an ad-hoc-signed rebuild raises one login-keychain dialog when reading a saved password — click **Always Allow**. Self-signed signing was tried and reverted (see the design doc). Design and threat model in [docs/design/password-vault.md](docs/design/password-vault.md). Open non-spec items, none started, **ask first** (§11): per-site content-blocking whitelist / runtime disable toggle; per-domain UA override map (§9.6). |
| **Post-M7 (non-spec)**           | Pinned tabs (three tiers, v8) · folders (v7) · per-Space history (v6) · **multiple windows + window layout (v9)** · **per-site camera/mic/notification permissions (v10, re-scoped v11)** · web notifications · YouTube ad skipping · UA setting · General settings · **password vault V1–V7 (v12, v13)** · **private windows** · **per-domain UA rules** (neither needs a migration). See §4.9 of the spec and the dated sections below. |
| **Branch**                       | `main` — single branch, linear history, one commit per milestone                                                                                                                                  |
| **Tests**                        | **558 passing** (`swift test`, 83 suites), measured 2026-08-01                                                                                                                                   |
| **Schema**                       | **v13** — … `v11_site_permissions_per_space`, `v12_credentials`, `v13_credential_never_save`                                                                                                      |

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

**Every spec milestone is done.** M1–M7 and content blocking (§4.8) shipped long
ago and are verified live. A long run of agreed post-spec additions has landed on
top (BROWSER_SPEC §4.9): multiple windows, folders, per-Space history, per-site
camera/mic/notification permissions, web notifications, YouTube ad skipping, the
UA setting, a **built-in password vault**, and — most recently — **private windows**.

State: single `main`, **558 tests**, `./scripts/prepush.sh` green, **schema v13**.

## Where the work is

**Nothing is assigned.** The newest work is **per-domain User-Agent rules**
(§9.6, 2026-08-01) — read that section for the two traps it turned up, one of
which (`customUserAgent` reading back as `""`) breaks navigation outright. Before
it, **private (incognito) windows, ⌘⇧N**
— read that section before touching any persistence path, because the feature is
defined by what it does *not* write, and two of its leaks were found only by
driving the real app. "New Blank Tab" moved to ⌘⌥N to free the binding.

Before it, the password vault was completed **V1 through V7**
(docs/design/password-vault.md), all of it verified live in the real browser:
saving, filling, management, and the lock (idle timeout, sleep, screen lock, Lock
Now, and an unlock required before a fill).

Open, non-spec, **ask-first** items (§11): a per-site content-blocking whitelist /
runtime disable toggle. (§9.6's per-domain UA map is **done** — 2026-08-01.)

The §6.1 gate is **current**: the soak was re-run 2026-08-01 with everything
since 2026-07-25 in place (notifications, site permissions, the vault, private
windows, per-domain UA) and passes with no leak — see the soak section below.
Still never run: the full Instruments GUI trace and sidebar-scroll fps.

## Vault rules you must not break

- **Secrets never enter SQLite, logs, or observable state.** Metadata rows in
  `credential`; passwords in the Keychain via `BrowserSecrets`, joined by id.
  `CredentialSavePrompt` deliberately has no password field — the secret sits in a
  private side table on `TabStore`.
- **Fill matching is exact origin equality** (scheme + host + port). No
  parent-domain matching, ever. The near-miss test table is longer than the happy
  path for a reason.
- **Never fill without a user gesture.** No fill on load, no fill on focus. There
  is exactly one caller of `fillCredential`, and it is a button.
- **The origin is re-checked inside the engine**, against the live `WKWebView`, at
  the moment of writing — not trusted from when the offer was made.
- **Filling uses the prototype value setter**, not `el.value =`. A direct
  assignment is swallowed by React's value tracker: the field looks filled and the
  form submits an empty string.
- `CredentialOrigin.Policy` is `.strict` everywhere in the app. Only `E2EHarness`
  relaxes it, and two tests exist to keep it that way.
- **The lock is evaluated lazily, never polled**, and a vault with no biometry and
  no device passcode fills rather than becoming unusable — reveal still refuses.
  Both are deliberate; see "Password vault V7".

## Traps that have already cost time here

**Never invent WebKit API.** Check the SDK headers under
$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/WebKit.framework/Headers/
That is how M4 learned `decidePlaceholderPolicy` is iOS-only and M6 learned
`WKFindResult` reports only `matchFound`.

**Verify UI work by driving the real app.** `screencapture -x -o out.png`,
`osascript` for keys, `cliclick` for the pointer (`dm:` not `m:` between `dd:` and
`du:`). `os.Logger` is NOT readable on this machine — if you need to see state,
render it on screen temporarily. That is how the V6 fill-button bug was found:
both its conditions were true, but the view computed matches in a `.task(id:)`
that raced the page load. **Page URL and login report arrive as separate
snapshots** — never key a task on both and assume they settle together.

**Before trusting a regression test, watch it fail against the bug.** This has paid
for itself repeatedly: it caught a loose origin matcher, an untested tokenising
rule, a missing shadow-DOM walk, and the naive `el.value =` fill. Break the fix,
see red, put it back.

**`swift test` runs UNSANDBOXED**, so it proves nothing about entitlements, the
Keychain under sandbox, or Hardened Runtime. Those need a real app, and Release
differs from Debug (the microphone needed a *second* entitlement key, ADR 014).

**Two test files assert `Migrations.currentVersion` literally.** A migration that
updates only one leaves prepush red after everything else looks finished.

**Do not repair a broken app bundle by re-signing it** — `xcodebuild ... clean
build`. Manual `codesign --force` cannot put it back, and the only place the real
reason appears is `~/Library/Logs/DiagnosticReports/Chord-*.ips`.

**The keychain dialog after a rebuild is expected**, not a bug: ad-hoc signatures
change every build and the item's ACL trusts the creating identity. Click "Always
Allow". Self-signed signing was tried and reverted — read that section before
suggesting it again.

Stage with `git add -A ':!Browser.xcodeproj/project.pbxproj'` and commit/push ONLY
when the user asks. Update CHECKPOINT.md in the same commit as the work it
describes.
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

### Self-signed code signing: tried, reverted (2026-07-31)

Aimed at the keychain prompt V6 uncovered — a rebuilt ad-hoc app is a *different*
code identity, so the vault item's ACL no longer matches and macOS asks for the
login-keychain password.

The mechanism worked: a self-signed certificate produces
`designated => identifier "com.rizal.browser" and certificate root = H"…"`,
identical across rebuilds. **The Debug bundle killed it.** It ships a nested
`Chord.debug.dylib`, and re-signing the app alone leaves that dylib on its old
signature; dyld then refuses to load it — *"mapping process and mapped file
(non-platform) have different Team IDs"* — which the user sees only as "Chord
cannot be opened because of a problem". The real reason is in
`~/Library/Logs/DiagnosticReports/Chord-*.ips`, and that file is the only way to
diagnose this class of failure.

Signing the nested dylibs first did not fix it, and neither did re-signing
ad-hoc by hand: the bundle stayed unlaunchable until a full
`xcodebuild clean build`. **If a broken bundle needs recovering, clean-build it —
do not try to repair the signature.**

Doing it properly means changing signing in `project.pbxproj` so Xcode signs the
whole bundle consistently, which this repo's git workflow deliberately keeps out
of commits. Reverted entirely: script deleted, certificate removed from the
keychain, app clean-rebuilt and verified running.

**Accepted cost instead:** click **Always Allow** on the keychain dialog once per
build. One dialog after a rebuild, none for a build you keep. It does train the
habit of approving keychain prompts, which is worth revisiting if the vault ever
ships to anyone but its author. An allow-any-application ACL stays refused.

### Link context menu: Open in New Tab / New Private Window (2026-07-31)

Right-clicking a link offered only WebKit's own menu plus "Open in Little Chord".
**"Open Link in New Tab" is Safari's item, not WebKit's** — tabs are the app's
concept, so the engine never provides one. Both new items follow the seam that
was already there for Little Chord (`ContextLinkMonitor` posts the href from a
capture-phase listener, `ChordWebView.willOpenMenu` decides visibility from
WebKit's own menu-item identifiers, the URL is read at click time).

- **Open Link in New Tab** → `paneRequestedBackgroundTab(url:fromPane:)` →
  `newTab(…, selecting: false)`. Background, and in the window showing the page
  the link came from — so in a private window it stays private. `newTab` gained
  a `selecting:` parameter (default true, so nothing else changed); the extension
  host is told the tab opened but not that it activated, because it did not.
- **Open Link in New Private Window** → `paneRequestedPrivateWindow(url:)` →
  `markNextWindowPrivate(opening:)` + a new `privateWindowPresenter`, set by
  `AppRootView` because SwiftUI's `openWindow` exists only in a scene's
  environment. Same shape as `littleArcPresenter`.

**The URL rides on the enum case** — `WindowKind.private(url:)` — rather than in
a second stored property beside the latch. The first cut had both cleared by one
`defer`, so `claimWindow` read the URL *after* it had been wiped and the window
opened on the new-tab page. A test caught it; carrying the payload on the case
makes the pair impossible to separate.

2 tests (543 total, prepush green), the background-tab one verified red against
sending it to the primary window in the foreground.

**NOT verified live — the one thing this project insists on.** The Mac locked
mid-session before the menu could be right-clicked on screen. Owed: right-click a
link and confirm the three items appear in order, that New Tab opens in the
background in the same window, and that New Private Window opens the *link*
rather than the new-tab page.

### The Space switch now moves (2026-08-01)

Switching Space only ever cross-faded the sidebar *gradient* — nothing travelled,
including during a swipe, where the finger dragged a colour blend and no content.
All three ways of switching now slide horizontally.

**One mechanism, deliberately.** `SpaceSwitchAnimator` drives the same
`spaceSwipeProgress` the trackpad gesture already drives, so a keyboard switch, a
click in the switcher, and a swipe are the *same* movement and cannot drift apart
as any of them is tuned. `SidebarView` turns that value into an offset and a
fade; nothing else knows how it is drawn.

**A switch is two phases**, because one does not read as travel: spring the
outgoing Space out to `±1`, commit, then *jump* the progress to the far side
(unanimated, off screen) and spring back to rest. Without the second phase the
new Space is simply present rather than arriving — a cut. The jump is invisible
because it happens to content already outside the sidebar. The swipe's release
path calls the same second phase, which it never had: a committed swipe used to
stop at "gone" and let the next Space appear.

**Only the sidebar moves.** The web content card hosts a live `WKWebView`, and §5
is explicit that layer transforms there cost the compositor fast path — so it
swaps as before. Arc slides its sidebar too. The travelling sections are
`.clipped()`, or they paint over the page for the length of the animation.

Reduce Motion collapses both phases to near-instant through the existing
`Motion.respectingReduceMotion`, so the setting still means what it says.

**Verified by the user by hand** — the honest form of verification for an
animation. Worth recording for the next attempt: `screencapture` cannot catch a
0.32 s spring (each still takes ~0.4 s, so the first frame already shows the
destination at rest). Slowing `Motion.spaceSwitch` to ~2.4 s, capturing, and
restoring it is the way to photograph one — and the restore is the step to not
forget.

### Downloads land in the real ~/Downloads again (2026-08-01)

Found while probing Peek. Every downloaded file was going to
`~/Library/Containers/com.rizal.browser/Data/Downloads/` — a path Finder's
Downloads never shows — so a download looked like it had silently failed.

**The entitlement was never the problem; the path lookup was.**
`FileManager.urls(for: .downloadsDirectory, in: .userDomainMask)` is rewritten by
the sandbox to the container, while `files.downloads.read-write` grants the real
folder. `DownloadCoordinator.userDownloadsDirectory()` now reads the home
directory from `getpwuid`, which the sandbox does not rewrite, and falls back to
the old lookup if that ever fails — a wrong directory beats no downloads.

M4's checklist recorded a live download to `~/Downloads`; either that check
looked at the container path too, or the behaviour changed under it. Worth
knowing that a green checklist line does not always mean what it says.

**`swift test` cannot catch this class of bug** — it runs unsandboxed, where the
old lookup returns the right answer. The 2 unit tests assert what is checkable
without a sandbox (the resolution names no `Library/Containers` path, and an
explicit directory still wins, which is what `E2EHarness` relies on); the proof
is the live run: an 8 KB file downloaded in the real app landed in `~/Downloads`,
byte-identical by `shasum`, with nothing in the container.

**"Completed — Zero kB", fixed the same day.** `updateBytes` ignores anything
arriving once the item is no longer active, and a download finishing inside one
chunk may deliver no KVO tick at all — so the row reported nothing for a file
plainly on disk. `recordFinalSize` now takes the count from the download's
progress at `downloadDidFinish`, falling back to the **file on disk**, which is
the ground truth. Live: a 65,536-byte file reads "Completed — 66 kB". The e2e
download test now asserts `bytesReceived`, and was verified red (0 vs 3500).

**A rebuild re-asks for Downloads access, and an unanswered prompt fails the
download.** Writing to the real `~/Downloads` is TCC-gated, and an ad-hoc
signature changes every build, so macOS treats each rebuild as a new app and
prompts again — the same mechanism as the keychain dialog. While the prompt sits
unanswered the destination callback is blocked and the download ends as "The
request timed out". Click Allow, then retry; it is not a code fault.

### Peek: a hover was downloading files, and firing on links you passed over (2026-08-01)

Two fixes to the ⌘-hover preview, both from a probe rather than a hunch: a local
page with a link to a 4 KB `application/octet-stream` file, a logging server, and
`CGEvent` mouse moves that actually carry the Command flag (a plain `cliclick`
move does not, so the page sees `metaKey == false` and Peek never fires — that
cost the first attempt).

**1. A ⌘-hover downloaded the file.** No click anywhere. Three hovers produced
three files — `peek-probe.bin`, `-1`, `-2` — and three entries in the Downloads
popover. The peek pane is an ordinary pane, so its navigation hit the response
policy, which turns anything WebKit cannot render into a `WKDownload`.

Fixed with a pane-level flag: `WebEngine.setPreviewOnly(_:paneID:)`, set by a new
`TabStore.peekSurface(for:)` and cleared in `discardLittleArc`. The response
policy cancels instead of downloading for those panes. **Little Arc keeps the
ordinary behaviour** — you clicked a link to get there, and can click one inside
it; a hover cannot consent to anything.

The fetch itself still happens, and cannot not happen: WebKit has to make the
request to learn the MIME type. So a peek is a real visit — worth remembering
next to "glance".

**2. No dwell delay.** `PeekLinkMonitor` posted on the *first* `mousemove` over a
link with ⌘ down, so sweeping across a list of links opened a preview per link,
each a real web view and a real page load. Now a 250 ms settle, cancelled if the
pointer moves on, and a twitch inside the link being previewed does not restart
it.

**Verified live after the fix**: the hover still previews on a deliberate rest;
the binary link fetches but writes nothing and creates no download entry; three
fast sweeps across both links open nothing at all.

2 e2e tests (556 total, prepush green) — the preview pane cancels, and a *normal*
pane still downloads, so the guard cannot quietly become a blanket ban. The first
was verified red against the original bug.

**Found while probing, since fixed (below):** downloads were landing in the
sandbox container, not `~/Downloads`.

### 30-minute soak re-run — the §6.1 gate means something again (2026-08-01)

The last soak was 2026-07-25. Since then: web notifications, per-site
permissions, the entire password vault (V1–V7), private windows, and per-domain
UA rules. Numbers in [SMOKE.md](SMOKE.md); the short version is **pass, with no
leak and no new steady-state cost**.

- App process **42 MB at start, 51–72 MB during, 51 MB at end** (target 150 MB).
- Total footprint **~694–716 MB, flat**, ending within 1 MB of its minute-1
  value (target 1.2 GB).
- Idle CPU **0.78%** over a 120-second cputime delta — under the 1% ceiling,
  above the 0.5% target, which is where the M7 and content-blocking soaks also
  landed. That target is a no-animation baseline and this fixture holds live
  pages.
- The 51/72 MB oscillation is which Space is on screen, not drift: the fixture's
  Spaces differ in live panes and one tab is a 4-pane split. Both values recur
  throughout and the run ends on the lower one.

Fixture was 3 Spaces / 21 tabs / 40 panes via `scripts/soak.sh seed`; the real
session was backed up to `browser.sqlite.presoak` and restored afterwards
(`integrity_check` ok, 2 Spaces / 10 tabs back, and a favourite that had been
navigated during the UA check was returned to its pinned URL).

### Per-domain User-Agent rules — §9.6, at last (2026-08-01)

The spec asked for this in §9.6 ("add a per-domain user-agent override map
**rather than a global spoof**") and what shipped first was the global spoof. It
fixes one site and breaks another — Google Meet refusing to start a call under
the Firefox UA is the standing example, and it has cost this project time twice.

- **`UserAgentRules`** (Core, pure): `normalise` accepts a pasted URL or a bare
  domain; `match` covers subdomains but **only on a dot boundary**, so
  `google.com` never matches `evil-google.com`; **the most specific rule wins**,
  so `meet.google.com → Default` carves an exception out of `google.com →
  Chrome`. `resolve` falls back to the global setting.
- **Applied per navigation**, in a new `decidePolicyFor navigationAction` on
  `NavigationCoordinator`. `customUserAgent` is read when the request is built,
  so setting it in the policy is too late for *that* request: when the UA
  changes, the navigation is cancelled and re-issued. Only for **GET** in the
  **main frame** — re-issuing a POST would silently drop the body.
- Settings → General → **Per-Site Rules**: domain field, preset picker, add and
  delete.

**Two bugs found while building it, both worth remembering:**

- **`customUserAgent` reads back as `""`, not `nil`, when unset.** So "did the UA
  change?" was always true, and the policy cancelled and re-issued *every*
  navigation forever. It presents as a page that never arrives, with no error.
  The e2e UA test caught it; a `print` in the policy showed the same URL being
  decided seven times. `applyUserAgent` now normalises empty to nil.
- **The settings sheet was silently clipping its own content.** `GeneralSettings`
  ended in `Spacer(minLength: 0)`, which inside the sheet's `ScrollView` absorbs
  the overflow instead of letting it scroll — the new section was rendered and
  unreachable. Removed. The other three sections still have that spacer and are
  short enough not to notice; they are a papercut waiting for the next addition.
- **An e2e test wrote to the developer's real `UserDefaults`.** `E2EHarness` now
  swaps in an `InMemoryPreferenceStore` *and* clears what the property
  initialisers already loaded from the real one — the initialisers run before any
  injection can happen. The symptom was a UA test failing on a rule it never set,
  left behind by a different test in an earlier run.

**Verified live (2026-08-01)** against `postman-echo.com/get`, which echoes the
request headers, with the global setting left on Default throughout:
a rule of **Chrome** → the echo reports Chrome; switching the same rule to
**Safari — iPhone** → the echo reports the iPhone UA on the next load; **deleting**
the rule → back to the browser's own `Version/26.5 Safari/605.1.15`.

12 tests (554 total, prepush green): 10 in `UserAgentRulesTests` (normalising,
the near-miss table, most-specific-wins, per-domain Default beating a global
spoof), 1 store test, and 1 **e2e** test asserting the header on the wire — the
only layer that can prove the resolved UA survives the navigation policy. The
matcher was verified red against both a bare `hasSuffix` and a first-match-wins,
and the e2e test against the empty-string bug.

### Private (incognito) windows — ⌘⇧N (2026-07-31)

**A private window is a window locked to a throwaway private `Space`.** That one
decision is the whole design: everything durable here is already Space-scoped —
`Tab.spaceID`, history, site permissions, the extension host's window-per-Space
model, and the data store itself, which `DataStoreRegistry` has built as
`.nonPersistent()` for an `isPrivate` Space since M2 (§3.3, ADR 006). The engine
half was already there; **nothing had ever set the flag.** So this was wiring a
switch that was already installed, plus suppressing every write path.

The Space is created in `claimWindow()`, appended to `spaces` (deliberately, so
the dozens of "resolve a Space by id" call sites keep working), and destroyed in
`unregister()`. `visibleSpaces` is what display and persistence enumerate.

**Decisions, made with the user before building:** ⌘⇧N takes the conventional
binding and "New Blank Tab" moves to ⌘⌥N; the window is locked to its own Space
(no switcher, no ⌘1…9, no pinned tiers, fresh cookies); the vault **fills but
never offers to save**.

**The channel is a one-shot latch** (`markNextWindowPrivate()`), not
`WindowGroup(id:for:)`. Two reasons, both about how this app already opens
windows: SwiftUI *dedupes* value-based windows, so a second private window with
an equal value would front the first; and a presentation value participates in
**scene restoration**, so macOS would hand "private" back at launch — the one
thing that must never resurrect a private session. The primary window is never
private, and `restore()` clears the latch.

**Suppression, one guard per funnel:** `persistSpaces` (→ `visibleSpaces`),
`performSave` (tab filter — both repository writes are delete-all-then-insert, so
filtering the input is complete), `captureWindowLayouts` (skip + renumber
ordinals), `captureLiveState`/`persistInteractionState` (a blob carries URL,
scroll, and form contents), `recordVisit`, the sweep's *candidate* list (not just
the archive write — `isSelectedByAnyWindow` protects only the selected tab),
`handleSubmittedLogin`, `recentlyClosed`, `resolveSitePermission`, `setPinned` /
`setBookmarked`, and a restore-side filter that drops a private Space found on
disk. Downloads are deliberately **not** suppressed — a saved file is a file.

**`reconcile`'s Space fallback is the most dangerous line in the change.** It was
a bare `spaces.first`, so a normal window whose Space vanished could adopt the
private one. Scoped now, and `applyLayout` too.

**`WebKitEngine.removeData(for:)` had a real bug for this feature**: it returned
early for a private Space *before* `dataStores.forget`, so a closed private
session's `.nonPersistent()` store stayed cached for the life of the process. The
forget moved above the guard.

**Two leaks the live drive found that the tests did not:**
- The private Space appeared in **every other window's Space switcher** — the UI
  enumerated `store.spaces`. Caught by looking at a screenshot of the normal
  window while the private one was open.
- The **command bar ranks open tabs from every Space**, so a normal window could
  have jumped straight into a private tab. `suggestions(for:in:)` is now scoped
  by the window's kind, and a private window sees no history or archive.

**Verified live** (screenshots, `sqlite3`, and the AX menu attributes):
1. File ▸ New Private Window, with the key equivalents read back — New Window ⌘N,
   New Private Window ⌘⇧N, New Blank Tab ⌘⌥N. The ⌘⇧N *keystroke* is not
   synthesizable, exactly as recorded for ⌘N; the menu item is.
2. The private window opens **signed out of Google** while a normal window is
   signed into the same account — the isolation, in one screenshot.
3. Its sidebar has no switcher, no favourites, and carries the honest footer.
4. While it was open: `space where isPrivate=1` → **0**, no `pane` row for its
   page, no `historyEntry` for it, and `windowLayout` counted only the normal
   windows.
5. Closing it left both normal windows painting, with a clean switcher.

Not re-driven by hand: quit-with-a-private-window-open (nothing private is on
disk, and the restore filter is unit-tested) and the save-bar suppression.

17 tests in `PrivateWindowTests` (541 total, prepush green). Eight were confirmed
red against deliberate breaks — the latch, the reconcile scoping, the layout
filter, and the space/tab/history/sweep/vault/command-bar guards. Two of them
were **found to be passing for the wrong reason** while doing it: the layout test
discarded its window (windows are held weakly, so there was nothing to filter),
and the first isolation test never reached the fallback line it claimed to cover.
Both were rewritten until the break actually turned them red.

### Password vault V7 — the lock (2026-07-31)

The last phase. The vault now locks, and a locked vault will not fill.

**Three ways it locks, and only the first is configurable.** An idle timeout
(`VaultLockTimeout` in Core, Settings → Passwords, default 15 minutes, with an
honest "Only on sleep or screen lock" instead of a "Never"), plus sleep, screen
lock, and fast user switching — those three are not settings, because they are
the cases where the user has demonstrably walked away. The event locks are wired
in `AppDelegate.attachVaultLockObservers` (`NSWorkspace.willSleep` /
`screensDidSleep` / `sessionDidResignActive`, plus the distributed
`com.apple.screenIsLocked`), which is where they belong: `BrowserStore` imports
no AppKit.

**Nothing polls.** `isVaultLocked` is recomputed at each vault touchpoint and
when a view asks (`refreshVaultLock()`), never on a timer — a repeating timer
writing observable state would redraw the chrome forever for a value that only
matters at the moment someone uses the vault (§6.4).

**The one judgement call worth not reversing by accident: `.unavailable` fills.**
With no biometry *and* no device passcode there is nothing to authenticate
against, so the fill proceeds rather than the vault becoming permanently
unusable — the attacker such a gate would stop already has the machine. `reveal`
still refuses in that case, because it is the one place a password becomes text
on screen. Both halves have a test.

`fillCredential` now returns **`CredentialFillResult`** (Store) rather than the
engine's `LoginFillOutcome`: a locked vault is not something the engine knows
about, and "the lock stopped this" needs saying differently to "the fields are
gone". Its `.filled(username:password:)` and `.originMismatch` cases keep the old
shapes, so the V4 e2e tests were untouched.

**A V6 bug the live drive found:** after saving a password, the fill key stayed
hidden until the tab navigated again — the per-pane refresh is driven by the page
*reporting* something new, and saving changes the answer with the page unchanged.
`refreshFillableCredentialsEverywhere()` now runs after a save and after a
delete. Verified red against the bug.

**Verified live in the real app**, each step screenshotted, using a throwaway
credential saved on `the-internet.herokuapp.com` (a public test login page with
published dummy credentials; deleted afterwards, `credential` back to 0 rows):

1. The vault is **locked at launch**; the toolbar key renders as `key.slash`.
2. Clicking it raises the real prompt — *"Chord is trying to unlock your saved
   passwords"*, with **Use Password…** beside Touch ID, which is the passcode
   fallback the done-when asks for.
3. Authenticating fills the form and the key turns unlocked.
4. **Cancelling fills nothing and says so** — the popover reads "Chord did not
   fill anything — the vault stayed locked because authentication was cancelled."
   It shipped clipped to one truncated line first: a popover sizes to its
   content, and `Text` given only a `maxWidth` collapses to the 24 pt anchor. It
   needs a fixed `frame(width:)`. Only visible on screen.
5. **Lock Now**, the **idle timeout** (a 1-minute setting locked it while a
   dialog sat on screen), **screen lock**, and **display sleep** each flipped an
   unlocked vault to locked, watched in Settings. Screen lock was driven by
   posting `com.apple.screenIsLocked` from a separate process — it *does* reach
   this sandboxed app — and sleep by `pmset displaysleepnow`.
6. The timeout preference survives a rebuild (`prefs.vaultLockTimeout`).

Steps 3 and 5 need an *unlocked* vault, which needs a real fingerprint, so they
were driven with a temporary auto-approving `VaultAuthenticator` in
`AppEnvironment` — **since reverted and clean-rebuilt** (the same scaffold-then-
revert shape as 7.5c). The keychain dialog appeared on each rebuild exactly as
documented; it was **denied**, not answered with a password, which is why the
fill in that run wrote nothing — the lock state is decided before the Keychain is
ever read, so the check still held.

11 new tests (524 total, prepush green), and three of them were confirmed red
against deliberate breaks: the fill gate removed, the idle clock frozen, and
`lockVault()` made a no-op.

### Password vault V6 — fill affordance, multi-step logins, and management (2026-07-31)

Three things, and the vault is now usable end to end in the real browser.

**The fill button** (`CredentialFillButton`, in the navigation bar) appears only
when the page shows a login *and* something is saved for that exact origin. One
account fills on click; several offer a menu first. Clicking it **is** the user
gesture threat-model rule 4 requires — there is still no automatic path to
`fillCredential` anywhere in the app.

**Multi-step logins now save a username** (the Google case V5 got wrong). The
collector reports a username-only submission too, and the store remembers the
last username per origin so the password step pairs with it. Kept in memory only:
a half-finished sign-in is not user data. A remembered username never crosses to
another origin, which has its own test.

**Settings → Passwords** lists every saved credential with its host, username, and
last use; **Reveal** is gated behind Touch ID (`VaultAuthenticator`), delete
removes both halves behind a confirmation, and silenced sites can be un-silenced.
Revealing deliberately does *not* count as a use — looking at a password is not
signing in with it, and counting it would make the picker's ordering meaningless.

**A live bug the tests could not have caught.** The fill button did not appear on
a real page, though its two conditions were both true — proved by temporarily
rendering the state on screen, since `os.Logger` is unreadable here. Cause: the
view computed its matches in a `.task(id:)`, and the page's URL and login report
arrive as **separate snapshots**, so the keyed task could settle before either was
final and leave the button hidden on a page that had a saved password. The fix
moves the computation into `TabStore.refreshFillableCredentials`, published on
`PaneRuntime` — the button is now a pure function of observable state with no
async race. **Verified live** afterwards: key appears, click fills.

**Ad-hoc signing costs a Keychain prompt after a rebuild (new finding).** Reading
a password saved by an *earlier build* raises the system "Chord wants to use your
confidential information…" dialog asking for the login-keychain password, because
the item's ACL trusts the creating code identity and an ad-hoc signature changes
every build. **The V1 probe missed this** — it tested exactly one rebuild and got
away with it. It does not affect a stable installed build. The right fix is a
**stable self-signed certificate** (free, no Apple account); "Always Allow" per
build works but trains a bad reflex, and an allow-any-app ACL is refused outright.

9 unit tests (512 total, prepush green), with the carry-over and the auth gate
both verified failing when removed.

### Password vault V5 — capture, the save bar, and the app wiring (2026-07-31)

The first phase you can see. Signing in on a page offers to save the password;
answering saves it; a relaunch offers it back. **`AppEnvironment.live()` now
builds the vault** (`SQLiteCredentialRepository` + `KeychainSecretStore`,
`.strict` origins) and reconciles orphan secrets at launch, so the subsystem is
finally real rather than test-only.

**Capture is page-side and fires on three cues**, because one is not enough:
a real `submit`, a click on a plausible submit control, and Enter in a password
field. Single-page apps often never submit a form — the button posts with
`fetch()` and the fields vanish — and losing the credential on exactly the sites
most likely to have one is not acceptable. Duplicates are expected and collapsed
in the store.

**Two suppressions decide whether the bar is tolerable**, and both are tested by
deliberately removing them:

- **Nothing is offered when the stored password is unchanged.** Asking every
  single time you sign in to a site you already saved is the behaviour that makes
  people switch a password manager off.
- **"Never" is remembered** (`credentialNeverSave`, schema **v13**) and silences
  the origin. A one-time "Not Now" does not — that distinction has its own test.

An existing login with a *different* password offers **Update**, not Save, and
updates in place rather than growing a second entry. The bar's wording differs
too: overwriting a working password by accident is worse than declining to save a
new one.

**The password is deliberately kept out of `@Observable` state.**
`CredentialSavePrompt` carries origin, host, username, and `isUpdate` only; the
secret sits in a private side table on `TabStore` keyed by prompt id, and is
dropped in *every* branch of the answer including the ones that do not save. A
`print(store)` or a crash log therefore cannot contain it.

`credentialNeverSave` is global rather than per-Space, unlike ADR 014's camera and
microphone grants: "do not offer to save here" is a statement about the *site*,
not about which identity you are using.

5 e2e tests (503 total, schema v13, prepush green), including V5's literal
done-when — sign in, offer, save, relaunch, offered back with the password intact.

**Not verified live.** The e2e server is HTTP and the vault is HTTPS-only in the
app, so the save bar has never been seen on screen. It needs a real sign-in on a
real site to confirm it appears and reads well. Also still missing: **any way to
fill from the UI** — V4's mechanism has no affordance, so a saved password cannot
yet be used. V6 should carry that.

### Password vault V4 — filling (2026-07-31)

`LoginFormFiller` + `WebEngine.fillLogin` + `TabStore.fillCredential`. The
mechanism is proven end to end; **nothing is wired into `AppEnvironment` yet**, so
none of it is reachable in the app until V5–V6 add UI.

**The whole difficulty is that `input.value = x` does not work on a modern page.**
React (and anything with a value tracker) installs an *instance* property
override that caches the last value it saw, and ignores an `input` event whose
value matches the cache. A direct assignment goes through that override, updates
the cache, and the framework concludes nothing happened — the field *looks*
filled and the app submits an empty string. The fix is to call the **prototype**
setter, which bypasses the instance override and leaves the tracker stale, then
dispatch `input` and `change` by hand because a programmatic change fires
nothing.

The e2e page reproduces that tracker exactly. **Verified failing against both
bugs**, and the shape of the failure is the point:

- naive `el.value = x` → the plain form still **passes**, the tracked form fails.
  That is precisely how this bug behaves in the wild: fine on simple sites,
  silently broken on React.
- no events dispatched → both fail.

**The origin is re-checked inside the engine, against the live `WKWebView`, at
the moment of writing** — not trusted from the offer. A page can navigate between
the two, and trusting the earlier decision is how a manager fills a bank password
into whatever loaded next. Rule 5 is re-checked in the page too: a field hidden
since the report is not filled.

**Threat-model rule 2 versus the test server.** The e2e server is plain HTTP on
loopback, and the vault refuses non-HTTPS origins. Rather than weaken the rule or
hide a `#if DEBUG` inside it, there is now an explicit `CredentialOrigin.Policy`:
`.strict` everywhere (the default argument, and what the app constructs) and
`.allowingInsecureLoopback` set in exactly one place, `E2EHarness`. Two unit tests
exist solely to stop that opt-in becoming the default, and to keep it narrow —
`http://localhost.evil.com` is still refused.

**Snag worth knowing:** a second `BrowserDatabase` over the same file fails with
"database is locked" (WAL contention). `E2EHarness` now exposes its `database` so
a test needing its own repository shares the one connection.

6 new tests (498 total, prepush green).

### Password vault V3b — the page-side collector (2026-07-31)

`PasswordFormMonitor`: a user script that collects a descriptor per input and
posts it, plus the wiring through `PaneSnapshot.loginForm` →
`PaneRuntime.loginForm`. **The script decides nothing** — `LoginFormClassifier`
(V3a) judges, which is what keeps the hard part testable without a browser.

Same family as `MediaActivityMonitor` (ADR 008) and `NotificationBridge`
(ADR 015): per-view content controller, handler removed in `tearDown()`, and a
`window.__chordLoginForms` singleton so re-injection at `atDocumentStart` is
idempotent. **Main frame only** (threat-model rule 3 — a credential is never
filled in an iframe, so there is no reason to look in one).

Three things the corpus forced, none of which a spec-reading implementation would
have:

- **Walks open shadow roots.** Reddit's login has zero inputs in the light DOM.
- **Live visibility** from rects + computed style, not attributes.
- **`MutationObserver`, debounced 150ms.** Every site in the corpus is an SPA
  whose form does not exist at `DOMContentLoaded`. Reports are deduplicated by
  signature, or a mutating page would post a message per animation frame.

The element handle is an **expando on the node** (`el.__chordFieldID`), not an
`id` attribute: writing an id into the page is a visible side effect that can
collide with the site's own CSS or JS.

5 e2e tests against real WebKit and real HTTP (492 total, prepush green), and
both risky features were **verified failing when removed**: deleting the shadow
traversal turns the Reddit-shaped test red, and stubbing out the MutationObserver
turns the late-rendering test red. Unit tests could not have caught either.

**V4 (fill) is next and is where the remaining risk sits** — setting a value that
React and friends actually notice needs the native-setter dance, which is why it
is an e2e concern rather than a unit-test one.

### Password vault V3a — the classifier, and what real login pages look like (2026-07-31)

The risky half of V3, done first and deliberately: **decide** which fields are a
login, validated against a corpus captured from the sites the user actually logs
into. The page-side collector is still to come.

**A spike loaded eight real login pages in a real `WKWebView` and dumped a
descriptor per input.** Every rule in `LoginFormClassifier` traces to one of these
findings — none of it is from reading the HTML spec:

| Site | What it actually does |
|---|---|
| **Reddit** | **0 inputs in the light DOM.** 46 shadow hosts; the fields exist only inside open shadow roots. Without shadow traversal the page is invisible to us. |
| **Google** | Renders a **hidden decoy** password field (`hiddenPassword`) on the username step. |
| **GitHub** | Ships three invisible `required_field_*` **honeypots**. Filling one is how a password manager gets its user flagged as a bot. |
| **Instagram / Facebook** | `autocomplete="username webauthn"` — multi-token, so `autocomplete == "username"` finds nothing. |
| **Mixpanel** | Password field is in the DOM from the start but invisible until the email step passes. |
| **npm** | **No `autocomplete` attributes at all** — name and label are the only signals. |
| **GitLab** | Served no login form to an automated WKWebView at all (bot wall). Not in the corpus. |

**The load-bearing rule is one line: invisible fields are ignored entirely.** That
single filter defeats Google's decoy, GitHub's honeypots, and Mixpanel's
not-yet-revealed field at once, and it is threat-model rule 5.

Also handled: multi-step logins (a username-only step and a password-only step are
both fillable, `isMultiStep`), signup/change-password forms (`new-password`, or two
visible password boxes — never filled from the vault), and one-time-code fields,
which must never be treated as a password even when rendered as `type=password`.

13 tests, 487 total, prepush green.

**Worth recording, because it is the working agreement earning its keep:** breaking
the classifier two ways showed the visibility filter was properly covered but
**tokenising was not** — the Instagram fixture passed even with `autocomplete`
compared as one string, because that field is *also* called `email` and keyword
fallback rescued it. A test whose only signal is the multi-token attribute was
added, and *that* one goes red. Without deliberately breaking the code, the suite
would have looked complete while proving less than it claimed.

**For the collector (V3b):** it must walk open shadow roots (Reddit), report live
visibility from rects + computed style, and re-run on DOM mutation (every SPA
here). Main frame only.

### Password vault V2 — metadata schema and the join (2026-07-31)

Schema **v12** (`v12_credentials`), the repository, and `CredentialVault` — the
one thing allowed to write both halves. Still no UI and nothing wired into the
app; V3 (form detection) stops for review first.

**Two schema decisions worth not re-litigating later:**

- `lastUsedSpaceId` **nulls** on Space deletion (`onDelete: .setNull`), it does
  not cascade. The vault is global by design, so the Space is a *hint* for
  ordering the picker, never ownership — deleting a Space must never delete a
  password. There is a migration test that deletes a Space and asserts the
  credential survives with a null hint.
- `(origin, username)` is unique, and `upsert` **keeps the existing id** on
  collision. That is not tidiness: a new id on re-save would leave the old
  Keychain item behind as a password the user can no longer see or delete.

**`CredentialVault` writes in a deliberate order in each direction.** Save writes
metadata *then* the secret; delete removes the secret *then* the metadata. Both
orders are chosen so an interruption leaves the *recoverable* state — a visible
credential the user can fix by saving again — rather than an invisible secret
nothing in the UI can reach. `reconcile()` drops secrets with no row, and
deliberately keeps rows whose secret has gone: which account you had on a site is
worth keeping even when the password is not.

A failed secret write rolls the metadata back **only for a newly created
credential**. Rolling back an update would delete a credential the user already
had because a re-save failed — the one rollback that must not happen, and it has
its own test.

25 new tests (474 total, prepush green). **Verified failing against the bug:**
making `upsert` mint a fresh id turns both orphan guards red.

**Snag worth knowing:** the schema version is asserted literally in *two* test
files (`ExtensionEnablementTests`, `GrantedPermissionsTests`), so every migration
has to update both or prepush goes red after everything else looks done.

### Password vault V1 — the secret half (2026-07-31)

Scope and reasoning: [docs/design/password-vault.md](docs/design/password-vault.md).
**V1 only** — storage, models, and the origin rule. No UI, no schema, no fill, and
nothing wired into the app yet; V2 (metadata schema v12) waits for review.

**Two pre-V1 checks, measured against a Release build** (sandbox + Hardened
Runtime + ad-hoc signature, `TeamIdentifier=not set`) with a temporary probe that
was then removed. `swift test` runs unsandboxed and could prove neither:

- **Plain Keychain items work with no entitlement**, and survive relaunch *and* a
  rebuild that changes the code signature. A vault will not be lost on every
  build, which for a project rebuilt several times a day was the real risk.
- **`SecAccessControl(.userPresence)` is unavailable**: `SecItemAdd` →
  `-34018 errSecMissingEntitlement`. Biometry itself is fine
  (`canEvaluatePolicy` true, Touch ID present) — it is the *protected item* that
  needs the data-protection keychain and an application-identifier entitlement,
  i.e. a real signing identity.

That second result **overturned the design's own recommendation**. The plan called
for an OS-enforced gate (the Keychain refusing to release an item without
biometry) precisely because it survives our own bugs. Not available here, so the
Touch ID gate is app-level: `VaultLock` evaluates `LAContext`, then reads an
ordinary item. **It is a UI lock, not a cryptographic one** — it stops a person at
your unlocked Mac, not code running as you — and that sentence belongs anywhere
the feature is described to the user. Moving to access-control items if a paid
identity ever exists is a re-write of every item, not a redesign; the note is in
`KeychainSecretStore`.

**What landed:**

- **`BrowserSecrets`**, a new package and the only importer of Security /
  LocalAuthentication — the same one-target-per-OS-boundary rule that gave
  `BrowserExtensions` its own target (ADR 011). `SecretStore` protocol,
  `KeychainSecretStore`, `VaultLockPolicy` (pure idle arithmetic),
  `VaultAuthenticator` + `BiometricAuthenticator`.
- **`Credential`** and **`CredentialOrigin`** in `BrowserCore` — metadata only,
  Foundation only. The secret never appears on the model, which is what keeps a
  password out of `browser.sqlite`, backups, and `.recover` dumps.
- **Matching is exact origin equality** (scheme + host + port), and the test table
  of near-misses is longer than the happy path: subdomains, suffix attacks
  (`example.com.evil.com`), scheme downgrade, port changes, punycode. **Verified
  failing against the bug** — swapping in the classic suffix match turns the
  subdomain cases red.
- 25 new tests (453 total, prepush green). The Keychain tests hit the **real**
  Keychain under a per-run unique service name, so they never touch the real
  vault and cannot collide between runs.

### Extension popups pin the sidebar open (2026-07-31)

**Bug, found by driving a real password-manager extension.** With the sidebar
collapsed, opening an extension popup and moving the pointer into it closed the
popup instantly. Mechanism: the popup is `WKWebExtension.Action.popupPopover`
shown against the sidebar-header button's `NSView`, and moving the pointer into
the popup *ends the hover that was revealing the sidebar* — the sidebar retracts,
the anchor leaves the window, and AppKit tears the popover down with it. Latent
since 7.5b; it hits **every** extension popup, not one extension.

The fix is the rule `RootView` already had for resize drags and Space sheets, with
a fourth condition: `WindowState.isSidebarHeldOpen` now includes
`isExtensionPopupOpen`. Both moved from the view into `WindowState` — a popup
belongs to one window (invariant 7b), and the move is what makes the rule
unit-testable at all.

Wiring, and why it is a broadcast: `WebKitExtensionHost` becomes the popover's
`NSPopoverDelegate`, reporting open at `show` and close from `popoverDidClose`
(AppKit is the only thing that knows about click-outside and Esc). It fires
`onPopupVisibilityChanged(window, isVisible)`, which `AppEnvironment` turns into a
`.extensionPopupVisibilityChanged` notification; each window's `RootView` filters
on identity against its own window. A plain closure would be **last-writer-wins
across windows** — the second window to open would silently steal the first's.
The window crosses the seam as an opaque `AnyObject` because `BrowserStore`
imports no AppKit and must not start.

5 tests in `ExtensionPopupSidebarTests`; **verified failing against the bug** by
deleting the condition (2 of the 5 go red on exactly the popup case), then
restored. 428 tests, prepush green. **Verified live** by the user: popup stays put
with the pointer inside it.

### Bitwarden does not work here — `chrome.offscreen` is unimplemented (2026-07-31)

The second extension-compatibility wall, and worth recording beside the AdBlock
one because the cause is **different** and the reflex "it's the rule limit" is
wrong here.

- AMO ships Bitwarden as **MV2** (persistent background page, `webRequestBlocking`)
  → rejected by our MV3 guard. The Chrome Web Store `.crx` is MV3 and is the only
  one worth testing.
- Loaded into a real `WKWebExtensionController`, the MV3 build reports
  `WKWebExtensionContextErrorDomain` **code 6 — "The background content failed to
  load due to an error"** about 2s after `load`, and its popup then spins forever,
  because every Bitwarden popup waits on the service worker to answer.
- **Root cause: `chrome.offscreen`.** Bitwarden's background bundle calls it 29
  times (plus `sidePanel`, `nativeMessaging`); WebKit does not implement
  `offscreen` and silently drops it from `requestedPermissions`, so the object is
  `undefined`, the worker throws while starting, and background content never
  loads.
- Established by control extensions rather than inference: a minimal MV3
  extension with a service worker loads **clean** (so service workers do work
  here), while one that touches `chrome.offscreen` and one that simply throws at
  top level both produce the *identical* code-6 error.
- **No code fix.** This is Apple's runtime being a subset, the same fact ADR 013
  and the AdBlock note record from other angles. Password managers that use
  `offscreen` for clipboard/crypto (most MV3 ones) will fail the same way; ones
  needing `nativeMessaging` (KeePassXC-Browser) fail too — also unimplemented.
- The probe script that produced this is worth rebuilding when the next extension
  misbehaves; the procedure is in the maintenance skill under "An extension loads
  but does nothing".

**Verification gaps carried out of this batch** (all need a human, not a test):
notifications end-to-end after an OS permission grant was confirmed on
`bennish.net`; the two-*distinct*-Google-accounts form of the isolation check and
the extensions-under-two-windows check remain unrun (no second credential set, no
extensions installed in this profile). No soak has been re-run since the content
blocking one (2026-07-25) — the batch added per-view scripts (notifications) and
a permission path, so a fresh 30-minute soak is the honest next measurement if
anyone wants the §6.1 gate to still mean something.
