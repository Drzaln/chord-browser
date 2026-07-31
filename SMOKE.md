# Manual smoke checklist

Run before calling a milestone done. Add to it as features land; never delete a
check that still applies.

## Build gate

```bash
./scripts/prepush.sh
```

Builds all packages, runs all tests, and builds the app — warnings as errors.
Baseline as of 2026-07-31: **512 tests in 79 suites**, schema **v13**.

A reminder that decides what belongs on this page at all: `swift test` runs
**unsandboxed**, so anything gated by an entitlement or an OS permission —
downloads, print, camera, microphone, notifications, data-store isolation — can
only be proved here, by hand, against the real app. And **Release differs from
Debug** for Hardened Runtime (see the microphone check under Site permissions), so
a feature touching device access needs a production build too.

## M1 — Browse

### Navigation

- [ ] App launches to a single window with a sidebar and one tab
- [ ] Typing a full URL (`https://example.com`) navigates
- [ ] Typing a bare host (`example.com`) navigates over https
- [ ] Typing multiple words runs a search
- [ ] Back / forward enable and disable correctly, and work
- [x] Reload works; the button becomes Stop mid-load (cancel still unchecked)
- [x] Progress bar appears during load (disappearance on completion unchecked)

### Tabs

- [ ] `Cmd+T` opens a new tab and selects it
- [ ] `Cmd+W` closes the current tab and selects a neighbour
- [ ] Closing the last tab opens a fresh one rather than an empty window
- [ ] Clicking a sidebar row switches tabs; the web view does not reload
- [ ] Title updates in the sidebar as pages load
- [x] Favicon appears in the sidebar, falling back to a globe when absent
- [ ] `target="_blank"` links open a new tab rather than being swallowed

### Persistence

- [ ] Quit and relaunch: tabs come back with titles and favicons
- [ ] After relaunch, no tab has loaded until it is clicked (check the debug
      overlay: live web views should be 1, not the tab count)
- [ ] Deleting the database file relaunches cleanly into one fresh tab
- [ ] Corrupting a row (e.g. blank a `pane.url`) drops that tab only, and the
      app still launches

### Crash recovery

- [ ] Kill a content process (`pkill -f "com.apple.WebKit.WebContent"` with the
      app in front): the page reloads itself and the app stays responsive
- [ ] Repeat while a second tab is open: the other tab is unaffected

### Performance (6.1 gate)

- [x] Cold launch to first interactive frame < 400 ms
- [x] Idle CPU with the window visible and nothing loading < 0.5%
- [x] Idle CPU with the window minimised ~0%
- [x] App RSS with 20 tabs / 5 live < 150 MB
- [ ] Sidebar scroll stays at display refresh with 20 tabs — still unmeasured,
      but screen recording **is** granted now, so frame capture is worth trying
      before calling it impossible.

Full §6.1 results are in the table below; they cover M1–M3 together, since the
gate had never been run for any of them.

## §6.1 budgets — measured 2026-07-23

Conditions: Apple Silicon, Debug build, 3 Spaces, 22 tabs, 12 live web views
(more than the 5 the budget assumes, so the footprint rows are measured under
heavier load than required).

| Metric                | Target   | Ceiling        | Measured       |      |
| --------------------- | -------- | -------------- | -------------- | ---- |
| App process footprint | < 150 MB | 250 MB         | **59–72 MB**   | pass |
| Total footprint       | < 1.2 GB | 1.8 GB         | **654–775 MB** | pass |
| Idle CPU, visible     | < 0.5%   | 1%             | **0.36%** app  | pass |
| Idle CPU, occluded    | ~0%      | 0.2%           | **0.01%** app  | pass |
| Cold launch           | < 400 ms | 800 ms         | **< 308 ms**   | pass |
| Space switch          | < 100 ms | 200 ms         | **< 1 ms**     | pass |
| Command bar open      | < 50 ms  | 100 ms         | **6–27 ms**    | pass |
| Sidebar scroll        | 120 fps  | no drops at 60 | not measurable | —    |

Read the CPU rows as the **app process alone**, consistent with the footprint
row that says "excl. content processes". Whole-tree idle CPU (app + WebContent +
GPU + Networking) was 1.17% visible and 0.11% occluded; the difference is live
pages animating, which is not an app-layer cost.

Caveats worth keeping honest:

- Cold launch is an upper bound. It is `open` → accessibility reports a window,
  and each accessibility probe alone costs ~144 ms, so the real number is well
  under 308 ms. In-app work is far smaller: the `launch` signpost (environment
  construction) is 4–6 ms and `restore` (22 tabs) is 55 ms.
- Space switch and command bar are **signpost intervals bounding app-side work**,
  not the compositor putting a frame on the display. A true first-painted-frame
  number needs the Instruments pass §6.7 asks for at M1/M3/M7, still not done.
- The first command bar open is 27 ms because the panel is built lazily; every
  open after is 6–10 ms.

### 30-minute soak — M6, measured 2026-07-24

Re-run for M6 (`scripts/soak.sh seed` then `run`), the fixture restored to
3 Spaces / 21 tabs / 36 panes (one 4-pane split per Space), driven with
Cmd+1…3 Space switches every 4 s for 30 minutes. M6 adds a permanent scroll
event monitor (swipe switching), a live-only sidebar drop layer, and a find
bar holding a cancellable task — none had been measured over a soak.

|                              | Start (settled, min 5) | End (min 30) |                   |
| ---------------------------- | ---------------------- | ------------ | ----------------- |
| App process footprint        | 50 MB                  | **43 MB**    | no growth — fell  |
| Total (app + WebKit helpers) | 426 MB                 | **410 MB**   | flat-to-declining |

No leak: the app process is flat at 40–50 MB across the run and 43 MB at the
end, and the total settles to ~410–418 MB from minute 5 and stays there. Both
clear the §6.1 budgets by a wide margin (app ≪ 150 MB, total ≪ 1.2 GB). The
early total spike to ~483 MB is web views coming alive on the first Space
switches; WebKit's own eviction then brings it down and holds it. Samples in
`/tmp/soak-060923.tsv` at the time of the run. Idle CPU and the Instruments
pass were not re-run for M6 — the M1 numbers above stand and the app layer did
not change shape.

### 30-minute soak — M7 (extensions), measured 2026-07-24

The §8/§6.6 gate for M7: a soak **with extensions across 3 Spaces**. Fixture is
3 Spaces / 21 tabs / 32 panes (one 4-pane split per Space) seeded with
**mainstream SPAs** — Google, YouTube, X, Instagram, Reddit, Wikipedia, GitHub,
Amazon (`SOAK_URLS=… scripts/soak.sh seed`, a new override) — far heavier than
the curated list. One extension (`soakext`: content script + background service
worker + `<all_urls>` host access) was enabled **in all three Spaces** via
pre-seeded `extensionEnablement` + `grantedPermission` rows, so it loaded on
launch through `restoreEnabled` and ran a per-Space worker (§6.6). Content-script
injection was confirmed on the live pages ("SOAK EXT ACTIVE" banner). Driven with
Cmd+1…3 Space switches every 4 s for 30 minutes.

|                              | Start (min 0) | Settled (min ~9) | End (min 30) |                 |
| ---------------------------- | ------------- | ---------------- | ------------ | --------------- |
| App process footprint        | 55 MB         | 64 MB            | **64 MB**    | flat, no growth |
| Total (app + WebKit helpers) | 317 MB        | ~470 MB          | **485 MB**   | flat            |

| §6.1 budget              | measured   | target   | ceiling |                |
| ------------------------ | ---------- | -------- | ------- | -------------- |
| App process RSS          | **64 MB**  | < 150 MB | 250 MB  | pass (wide)    |
| Total footprint          | **485 MB** | < 1.2 GB | 1.8 GB  | pass (wide)    |
| Idle CPU, window visible | **0.63%**  | < 0.5%   | 1%      | under ceiling¹ |

**No leak.** The app process rises 55→64 MB in the first ~9 minutes (warm-up as
per-Space workers and initial pages load) and is then **flat at 64 MB** for the
remaining 20+ minutes. Total peaks ~747 MB during the first Space-switch wave
(every mainstream SPA coming alive at once), then WebKit's eviction (§6.2) brings
it down and **holds it at ~470–485 MB** — a +15 MB drift over the last 20 minutes,
within noise. Process inventory at the end: 1 app + 5 WebKit helpers (1
networking, 3 WebContent, 1 GPU) — the three per-Space extension workers did
**not** balloon the process count; WebKit consolidates them.

That mainstream SPAs + three extension workers still settle to **485 MB total and
64 MB app** — a third of the 1.2 GB budget and under half the 150 MB app target —
is the headline: the extension subsystem adds no measurable app-process cost, and
per-Space isolation does not multiply footprint the way a naive design would.

¹ Idle CPU was measured on the app process after the run, with the mainstream
SPAs still live. The **0.5% target is a "no animation" baseline**; YouTube,
Reddit, et al. run background timers/compositor updates continuously, so a truly
idle reading is not available with this fixture. 0.63% is comfortably under the
1% ceiling; the cheap-site M6 soak (near-flat CPU) is the no-animation reference.
Samples in `/tmp/soak-220853.tsv` at the time of the run. Instruments
Allocations/Leaks (§6.7) still not run — carried debt, same as M1/M3/M6.

### Cosmetic `:has()` filtering, verified 2026-07-25

`:has()` element-hiding rules were previously dropped on the assumption WebKit
could not compile them. Verified end-to-end that it can:

- **Compile:** `WKContentRuleListStore.default().compileContentRuleList` accepts
  `css-display-none` with selector `div.wrap:has(> a.ad)` (throwaway probe).
- **Runtime hide:** attaching that list to a live `WKWebView` and loading a page
  with `<div class=wrap><a class=ad>` gave `getComputedStyle(.wrap).display ==
  "none"` while a control `.wrap2` stayed `"block"`.
- **Impact:** recovers ~595 container-hiding rules from EasyList alone (more from
  EasyPrivacy / regional lists) that were dropped before.
- **Still dropped:** proprietary procedural cosmetics (`:upward`, `:xpath`,
  `:-abp-`, `:has-text`, `:matches-css`) and any selector mixing `:has()` with
  them — see `ContentBlockConverterTests`.

- [x] A `##…:has(…)` rule is kept and hides the matching container
- [x] A `##…:upward(…)` / `:xpath(…)` rule is dropped, not mis-parsed as a URL

### 30-minute soak — content blocking (C4), measured 2026-07-25

The §8/§4.8 gate for the content-blocking milestone: a soak with **blocking on**.
Same mainstream-SPA fixture as the M7 soak (3 Spaces / 21 tabs / 32 panes over
Google/YouTube/X/Instagram/Reddit/Wikipedia/GitHub/Amazon), with
`FeatureFlags.contentBlockingEnabled` on via a temporary `AppDelegate` scaffold
(reverted). On launch the seed compiles instantly and the weekly refresh fetches
the full EasyList + EasyPrivacy and compiles ~50k rules off-main. 30 minutes of
Cmd+1…3 Space switches.

|                              | Start (min 0) | Settled (min ~10) | End (min 30) |                 |
| ---------------------------- | ------------- | ----------------- | ------------ | --------------- |
| App process footprint        | 32 MB         | 60 MB             | **58 MB**    | flat, no growth |
| Total (app + WebKit helpers) | 297 MB        | ~465 MB           | **464 MB**   | flat            |

| §6.1 budget              | measured     | target   | ceiling |                |
| ------------------------ | ------------ | -------- | ------- | -------------- |
| App process RSS          | **58–60 MB** | < 150 MB | 250 MB  | pass (wide)    |
| Total footprint          | **464 MB**   | < 1.2 GB | 1.8 GB  | pass (wide)    |
| Idle CPU, window visible | **0.56%**    | < 0.5%   | 1%      | under ceiling¹ |

**No leak, and content blocking adds no measurable steady-state cost.** The
numbers are within noise of the M7 soak (64 MB app / 485 MB total) — the compiled
rule list is a shared, immutable object, so attaching it to every view costs
almost nothing, and the compile is a one-time transient. **The compile spike is
transient and off-main:** the app process read ~103 MB _during_ the full 50k-rule
compile at launch, then released to **32 MB** once done (well under budget), and
the window was interactive at t+3 s — the compile never blocked launch (§6.6).

**Content blocking verified live (A/B, 2026-07-25):** with blocking **on**,
navigating to a blocked tracker (`googletagmanager.com/gtm.js`) was stopped
before the network (the page stayed on the previously loaded `example.com`);
with blocking **off** the identical navigation reached the server (Google's own
404). `example.com` loaded normally with blocking on, so ordinary browsing is
unaffected. This is the decisive proof the attached list is enforced at runtime.

¹ Same caveat as the M7 soak: measured with mainstream SPAs still live, whose
background timers keep the app just over the no-animation 0.5% target but under
the 1% ceiling. Content blocking is passive rule-matching in WebKit — it adds no
timers and no idle CPU. Samples in `/tmp/soak-052928.tsv`.

## Frosted-glass chrome, added 2026-07-25

The docked sidebar and the border frame use `.ultraThinMaterial` (same as the
collapsed sidebar); the window is non-opaque so the material blurs the desktop.

**Verified live 2026-07-25:** launched the app; the docked sidebar and the frame
around the web card render as frosted glass with the Space tint, the web page
stays opaque, and the extension buttons sit on the glass. Screenshot captured.

- [x] Docked sidebar is translucent frosted glass (not a flat fill)
- [x] The border frame around the web card is frosted too
- [x] The web content card stays opaque (no desktop bleed through the page)
- [ ] Collapsed/floating sidebar still frosts correctly (unchanged path)
- [ ] Space swipe still blends the tint under the glass
- [ ] No compositor/perf regression over a soak (re-run §6.1 if in doubt — the
      non-opaque window + behind-window blur is new GPU work for the chrome)

## Settings (clear browsing data + extensions), added 2026-07-25

User-requested non-spec features. Sheet opens with `Cmd+,` or app menu →
*Settings…*. It now has **three** sections, not two — **General** (search engine,
new-tab behaviour, User-Agent, archive window) came later; its UA checks are under
"User-Agent setting" below, and the per-site permission list that now sits at the
bottom of Privacy & Data is under "Site permissions".

**Verified live 2026-07-25:** launched the built app, `Cmd+,` opened the sheet;
the **Privacy & Data** section renders the four toggles (cache, cookies, local &
session storage, history), the **Clear Data** button, and the "cleared for every
Space… cannot be undone" copy. Screenshot captured. (The Extensions tab's own
screenshot was blocked by a macOS screen-recording permission dialog, which was
**not** actioned — it's a system prompt; the tab is the same `SettingsView` and
its service actions are unit-tested.)

### Privacy & Data
- [x] `Cmd+,` opens the settings sheet
- [x] Privacy & Data shows cache / cookies / storage / history toggles
- [ ] Clearing **cache** frees disk without signing out (manual A/B)
- [ ] Clearing **cookies** signs you out of a logged-in site, in every Space
- [ ] Clearing **history** empties the command-bar history suggestions
- [x] Clear Data asks for confirmation before acting (irreversible)

### Extensions
- [x] **Add Extension…** opens a file picker; a `.crx`/`.xpi` installs and lists
      (verified live: AdBlock + Enhancer for YouTube, both MV3, listed)
- [x] The **Enabled** switch loads/unloads the extension in the active Space
- [x] **Enabling prompts for host access** (verified live 2026-07-25: enabling
      Enhancer for YouTube showed a sheet listing its real requested patterns —
      `*://www.youtube.com/*`, `/embed/`, `/shorts/`, `youtube-nocookie` — read
      from the loaded `WKWebExtension`; Allow granted + the tab reloaded)
- [ ] Enabling in Space A does not enable it in Space B (per-Space)
- [ ] The trash button uninstalls (gone from every Space + the library)
- [ ] An enabled extension's toolbar button appears in the sidebar header
- [ ] Enhancer for YouTube's on-page controls render after grant (last mile —
      mechanism verified, extension-specific UI not screenshot-confirmed)
- [ ] AdBlock actually blocks (WebKit's `declarativeNetRequest` is partial —
      expect limited blocking; not a full replacement for built-in blocking)

**Note on why they "didn't work" before:** enabling loaded the extension but
never granted host access (WebKit does not prompt for required `host_permissions`),
and tabs open before enabling had no controller attached. Both fixed 2026-07-25 —
see CHECKPOINT "Extensions-not-working fix".

Automated coverage: `ClearBrowsingDataTests` (Store fan-out), `BrowsingDataType`
+ `WebsiteDataTypeMapping` (type mapping), `HistoryClearTests` (deleteAll),
`ExtensionsServiceTests.removeUnloadsFromAllSpacesAndDeletesFromDisk`.

## M2 — Spaces

### Switching

- [ ] The Space strip appears at the top of the sidebar
- [ ] Clicking a Space switches the tab list to that Space's tabs
- [ ] `Cmd+1`…`Cmd+9` select Spaces by position
- [ ] A shortcut for a Space that does not exist does nothing
- [ ] Switching back to a Space returns to the tab you were last on
- [ ] Switching to an empty Space opens a new tab in it
- [x] The sidebar gradient changes with the active Space (the _animation_
      itself still needs an eye — stills cannot show it)
- [ ] Reduce Motion collapses the animation without breaking the switch

### Isolation — the M2 done-when

- [ ] Log into Google in Space A
- [ ] Switch to Space B, open the same site: **you are logged out there**
- [ ] Log into a _second_ Google account in Space B
- [ ] Switch back to Space A: still the first account, no re-auth
- [ ] Quit and relaunch: both sessions survive independently

### Managing Spaces

- [ ] "+" adds a Space with a distinct gradient, and activates it
- [ ] Right-click a Space → Delete asks for confirmation first
- [ ] Deleting removes its tabs and its cookies (log in, delete, recreate a
      Space, confirm you are logged out)
- [ ] The last remaining Space cannot be deleted
- [ ] Right-click a tab → Move to Space moves it, and the page reloads clean
      (it must not carry the old Space's session)

### Migration from v1

- [ ] A profile created before M2 opens with all its tabs in a "Personal" Space
- [ ] A pre-migration backup exists in `Backups/`

## M3 — Command bar + ephemeral tabs

### Command bar

> Verified live via accessibility automation: open, focus, type, Enter,
> Cmd+Enter, and Esc all confirmed against the running app. The unticked items
> below still need a human eye.

- [x] `Cmd+T` opens the bar, input focused and accepting keystrokes
- [x] Enter opens the highlighted result and dismisses the bar
- [x] `Cmd+Enter` forces a new tab instead of navigating the current one
- [x] Esc dismisses
- [x] `Cmd+N` still opens a plain new tab
- [x] An already-open tab outranks history for the same term (§4.4)
- [x] The bar is visually centred and legible over the window
- [x] The result list is actually visible — the panel grows to fit its rows
      (it did not, for all of M3: the panel was a fixed 60 pt tall)
- [x] The app behind it does not visibly activate or lose its selection
- [ ] Typing filters with no perceptible lag
- [x] Up/down arrows move the highlight and wrap at the ends
- [x] An open tab in _another_ Space is findable, and its row names the Space
- [x] Commands ("new space", "close tab") are reachable by name

## M5 — Split view + Little Arc

### Split view

- [x] `Cmd+Shift+D` splits the focused tab into two panes of equal width
- [x] The focused pane is visibly marked; the ring only appears when split
- [x] **Dragging a divider tracks the cursor smoothly** and resizes the two
      adjacent panes only — verified with `cliclick`: a 100 pt drag over a
      663 pt content area moved the split 0.5 → 0.3492, exactly the cursor
      delta
- [ ] The resize cursor appears over a divider

### Drag a tab into a split (§4.5)

Verified 2026-07-23 by driving the real app with `cliclick` and reading the
result from screenshots and `browser.sqlite` — not from the test suite, which
cannot stage an AppKit drag session. Use `dm:` between `dd:` and `du:`.

- [x] Dragging a sidebar row over the content area highlights the pane it would
      land in
- [x] Dropping adds it as a pane, and the dragged row disappears from the
      sidebar (it is moved, not copied)
- [x] Dropping onto a tab that already has 4 panes is refused, and the dragged
      tab is still in the sidebar afterwards — confirmed against the database
      (`4` panes before and after, source tab row still present)
- [x] Dragging a row onto itself does nothing
- [x] **A cancelled drag** (released away from a pane) leaves the page
      clickable — the drop layer is torn down, so a link under the cursor still
      follows. This is the one that regresses silently: a stale flag leaves an
      invisible layer over the web view eating every click
- [x] **Ending a drag does not select the row that was dragged.** Found here,
      not in tests: the drag source cleared its own flag when the session ended,
      so the mouse-up that sometimes arrives afterwards read as a plain click
- [x] Clicking an unfocused pane focuses it _and_ the click still reaches the
      page (a link under the cursor should follow)
- [x] Splitting four times stops at four panes
- [x] `Cmd+Shift+Opt+D` closes the focused pane; down to one converts the tab
      back to a normal tab with no divider
- [x] Pane widths survive quit and relaunch (a 4-pane tab restored equal-width,
      and lazily — no web view until it was shown)

### Little Arc (§4.6)

- [x] A web link from another app opens the floating panel, not a tab
- [x] The panel appears at the cursor, borderless, over the main window
- [x] `Cmd+O` promotes it into a real tab in the active Space, and the panel
      closes
- [x] Esc dismisses without creating a tab, and tears the web view down
- [ ] The panel appears even when the main window is closed, and the app does
      not quit while it is up
- [ ] A link arrives already logged in to the active Space's session
- [ ] Opening a second link replaces the first panel rather than stacking
- [ ] The scale-and-fade entry reads well, and Reduce Motion skips it
- [ ] Browsing inside the panel and _then_ promoting keeps where you got to

### Window chrome

- [x] No dead band above the web content — the card starts at the top inset,
      not below a reserved titlebar strip
- [x] Traffic lights clear the Space switcher without overlapping it
- [x] The window is still draggable by its top edge
- [ ] **Known broken:** double-clicking the top edge no longer zooms the window.
      The content runs under the titlebar strip since the dead-band fix, so the
      double-click never reaches it. Deferred to M6 polish; the fix is a real
      drag/zoom region rather than reverting the layout.

### Visual sweep — 2026-07-23

Screen recording is granted, so these were checked by screenshot rather than
left to a human eye. It is how the clipped result list was found; everything
below had passed its _behavioural_ check for two milestones while never once
being looked at.

Two things the sweep turned up, neither fixed:

- **The fuzzy matcher is very loose.** Typing `goo` matched "WKDownloadDelegate
  | Apple Developer Documentation", because `FuzzyMatch` accepts any
  subsequence and those letters appear scattered across it. It ranks last, so
  it is noise rather than a wrong answer, but it fills the list with results a
  user would not call matches. Wants a minimum-quality floor, not just a score.
- **History records interstitials.** A Cloudflare "Just a moment…" page is in
  history with its challenge URL. `recordVisit` skips blank and error pages but
  has no notion of a challenge page.

Still not covered, and still needing a human: the gradient _animation_ and
sidebar scroll smoothness (stills cannot show motion), Reduce Motion (a system
setting this sweep did not change), and whether typing "feels" lag-free.

### Cmd+T vs Cmd+L (§4.4, changed after M4 review)

- [x] `Cmd+T` + Enter opens the result in a **new** tab, leaving the current one
- [x] `Cmd+L` + Enter navigates the **current** tab, opening nothing new
- [ ] `Cmd+Enter` forces a new tab from either mode
- [x] Typing a complete address (`github.com`) highlights that address, **not**
      an open tab that happens to fuzzy-match it
- [x] Typing a word (`github`) still highlights the open tab, with the search
      fallback last
- [x] Every row shows what Return will do — a cross-Space result reads
      "Switch to Tab" _before_ you press it

### Ephemeral sweep

- [ ] A tab left idle past the window is closed automatically
- [ ] The tab you are looking at is never closed
- [ ] A pinned tab is never closed
- [ ] A tab playing audio is not closed (open a video, leave it playing)
- [ ] Setting the idle window to "never" disables sweeping entirely
- [ ] Swept tabs are findable in the command bar and reopen correctly
- [ ] The archive survives quit and relaunch
- [ ] Minimise the window: no sweeping happens while it is hidden

### Migration from v2

- [ ] An existing profile opens with history and archive tables added, tabs intact

## M4 — Session restore + downloads

### Restore

> `interactionState` is written on tab _deactivation_, on occlusion, and on
> quit. A force-quit still loses whatever happened since the last switch — there
> is no way around that, which is exactly why capture is not left to quit alone.

- [x] Quit and relaunch: a tab's back/forward history still works (verified e2e —
      a tab that merely reloaded its URL cannot go back, so this distinguishes
      real restore from a reload)
- [x] After relaunch, no tab has loaded until it is clicked
- [x] `paneInteractionState` has rows after a normal quit (it had none before M4;
      check with `sqlite3 browser.sqlite "select count(*) from paneInteractionState"`)
- [ ] Scroll position comes back on a long page
- [ ] Text typed into a form comes back
- [ ] Switch tabs, then force-quit: the tab you switched _away_ from restores,
      the one you were looking at may not
- [ ] Closing a tab drops its stored state (count above goes down after a save)

### Downloads

- [x] A link to a non-renderable file downloads instead of doing nothing
- [x] The file lands in ~/Downloads and is byte-for-byte correct (verified in the
      real sandboxed app — `swift test` runs unsandboxed and cannot prove this)
- [x] A second download of the same name becomes `name-1`, it does not overwrite
- [x] The progress bar advances on a large, slow download
- [ ] A download with no `Content-Length` shows an indeterminate bar, not 0%
- [x] Cancel actually stops the transfer
- [ ] Clearing a finished row leaves the file on disk
- [x] The downloads button is hidden until there is something to show

## M6 — Polish

### Find-in-page (§8, M6)

- [x] `Cmd+F` opens the bar with focus in the field
- [x] Typing searches as you go; `Cmd+G` / `Cmd+Shift+G` step matches
- [x] A miss says "Not found" and outlines the bar; an _emptied_ field says
      nothing rather than flashing "Not found" on every backspace
- [x] Esc and the close button dismiss it and clear the page's highlight
- [x] In a split, Cmd+F searches only the focused pane (unit-tested; confirm by
      hand that the other pane does not scroll)

### Command bar as the way in (§4.4)

- [x] The sidebar's **New Tab** button opens the command bar, not a blank tab
- [x] **`Cmd+Shift+D`** opens the command bar, and Return puts the result in a
      new _pane_ — the tab count does not change
- [x] In split mode the rows read "Move to Split" / "Open in Split", not
      "Switch to Tab"
- [x] A plain blank tab is still one keystroke away — **`Cmd+Shift+N`** since
      multi-window took `Cmd+N` for New Window (was `Cmd+N`; verified there)
- [ ] `Cmd+Enter` from split mode forces a new tab rather than a pane
      (unit-tested; confirm by hand)
- [x] `Cmd+Shift+D` on a tab that already has 4 panes — the store declines, so
      check the bar does not leave you with a dismissed panel and no feedback

### Sidebar: hide and reveal (§4.1)

Verified 2026-07-23 by driving the app. Read the state without a screenshot by
sampling a pixel that is sidebar when revealed and page when hidden
(`screencapture -x -R560,400,4,4`). Get the window's real frame from
`osascript ... get position of window 1` rather than estimating it off a
screenshot — a 6-point strip does not survive a guess.

- [x] `Cmd+S` and the sidebar button hide it **completely** — no rail, content
      fills the window
- [x] **Reaching the window's left edge reveals it** over the page, as a
      floating card, without shifting web content
- [x] Leaving hides it again after a delay; re-entering cancels that
- [x] The traffic lights are hidden while the sidebar is, and return with it
- [x] The hidden state survives relaunch
- [ ] The reveal strip does not swallow clicks. Note it currently overlaps only
      the content card's 8-point inset, not the web view, so this is untested
      in practice — it will matter if the inset ever goes away

### Favourites (§4.1)

- [x] "Pin to Favourites" moves a tab from the list into the grid
- [x] The grid is 4 tiles per row, favicon only, and selection is visible
- [x] Unpin returns it to the ephemeral list
- [x] A Space's favourites do not appear in another Space
- [ ] Favourites survive relaunch (the placement is persisted from M1; confirm)
- [ ] Double-click a favourite tile returns it to its home URL
- [ ] "Set Current Page as Pinned URL" re-homes a favourite to the current page
- [ ] Closing a favourite (Cmd+W) unloads it but keeps the tile and its favicon

### Pinned tabs (§4.1a)

- [ ] "Pin Tab" moves an ephemeral tab into the Pinned list (above New Tab)
- [ ] Clicking an already-selected Pinned row returns it to its home URL
- [ ] "Set Current Page as Pinned URL" re-homes a Pinned tab
- [ ] Closing a Pinned tab keeps the row and returns it to its home URL, favicon intact
- [ ] The Pinned header collapses/expands the list; the count shows while collapsed
- [ ] Collapse state is per-Space and survives relaunch
- [ ] A Pinned tab is exempt from the idle sweep
- [ ] Drag a tab onto the Pinned section to pin it; drag out to unpin

### 30-minute soak

- [x] 20 tabs open, cycle through them repeatedly for 30 minutes
- [x] Record footprint at start and end (debug overlay, `Cmd+Ctrl+P`)
- [x] Growth over the soak means a leak — investigate before moving on

Start: **70** MB End: **62** MB

Run 2026-07-23 on Apple Silicon: 3 Spaces, 22 tabs, 12 live web views (the pool
cap), Space switched every 4 s for 30 minutes, sampled every 60 s.

|                          | start  | end    | range         |
| ------------------------ | ------ | ------ | ------------- |
| App `phys_footprint`     | 70 MB  | 62 MB  | 59–72 MB      |
| App + all WebKit helpers | 720 MB | 727 MB | 654–775 MB    |
| Live web views           | 12     | 12     | 12 throughout |

No growth over 30 minutes — the app process finished _lower_ than it started,
and the total oscillates around a flat mean. No leak signal.

#### M5 re-run, 2026-07-23

§8 gates every milestone on this, and the run above predates split view and
Little Arc — both of which add live web views (a 4-pane tab is 4 at once).
Re-run with `scripts/soak.sh`, which did not exist before and is why the soak
had been run exactly once: `seed` writes the fixture, `run` drives and samples.

3 Spaces, 21 tabs (one per Space is a 4-pane split), 12 live web views, Space
switched every 4 s for 30 minutes, sampled every 60 s. Started from a
_restored_ session, so lazy restore is on the path.

|                          | start  | end    | range         |
| ------------------------ | ------ | ------ | ------------- |
| App `phys_footprint`     | 60 MB  | 58 MB  | 58–60 MB      |
| App + all WebKit helpers | 555 MB | 498 MB | 497–555 MB    |
| Live web views           | 12     | 12     | 12 throughout |

| §6.1 budget        | measured | target   | ceiling |
| ------------------ | -------- | -------- | ------- |
| App RSS            | 58 MB    | < 150 MB | 250 MB  |
| Total footprint    | 498 MB   | < 1.2 GB | 1.8 GB  |
| Idle CPU, visible  | 0.083%   | < 0.5%   | 1%      |
| Idle CPU, occluded | 0.006%   | ~0%      | 0.2%    |

No leak: both figures end _below_ where they started, the total declining
monotonically as WebKit reclaims. Split view costs nothing structural — a
4-pane tab is four panes against the same 12-view cap, not four extra.

#### Post-M7 Pinned-tabs re-run, 2026-07-26

Exercises the three-tier model (§4.1a) and, separately, real heavyweight sites.
Seed spans all tiers: 3 Favourites + 3 Pinned (both homed) + 15 ephemeral, one
4-pane split per Space. Space switched every 4 s, sampled every 60 s, from a
_restored_ session.

Light fixture (`example.com`-class), 5 min:

|                          | start  | plateau (min 1–4) |
| ------------------------ | ------ | ----------------- |
| App `phys_footprint`     | 54 MB  | 67 MB (flat)      |
| App + all WebKit helpers | 109 MB | 727 MB (flat)     |

Mainstream fixture (top-16 of the Wikipedia most-visited list — google,
youtube, facebook, instagram, chatgpt, x, reddit, bing, tiktok, wikipedia,
yahoo, amazon, linkedin, baidu, naver, yandex), 7 min, via
`SOAK_URLS="…" scripts/soak.sh seed`:

|                          | start  | peak (min 2) | settled (min 3–6) |
| ------------------------ | ------ | ------------ | ----------------- |
| App `phys_footprint`     | 38 MB  | 68 MB        | 68 MB (flat)      |
| App + all WebKit helpers | 302 MB | 779 MB       | ~660 MB (flat)    |

No leak on either: the app process is flat, and the total warms to a transient
peak while every Space's SPAs load at once, then WebKit reclaims to a flat band.
Both runs were shorter than the §8 gate of 30 minutes (run budget) — the plateau
is clear, but do a full 30-min pass by hand before treating this as shippable.

### How to re-run the measurements

Footprint was read with `footprint -p <pid>`, which reports the same
`phys_footprint` the debug overlay shows, so the two are comparable.

Idle CPU must be measured as a **CPU-time delta** over a window
(`ps -o cputime=`), not with `ps %cpu` — the latter is an average over the
process's whole lifetime and will happily report a healthy number for an app
that has been spinning for the last minute.

**Parse `cputime` by field count, never by assuming a shape.** It prints
`MM:SS.ss` under an hour of CPU and `HH:MM:SS` over it. Reading the short form
as the long one multiplies the answer by 60: the M5 run first measured 8.67%
visible idle — nearly 9x the ceiling — and it was 0.083%. What caught it was
`sample`, which put the main thread in `mach_msg2_trap` for 13030 of 13031
samples, i.e. doing nothing at all. **Confirm a budget failure with `sample`
before believing it**, in both directions: the same tool cleared the transient
below and this false alarm.

Measure idle only after letting the app **settle for 3–4 minutes**. Sampled
immediately after the soak, the occluded app process read 0.29% — over its 0.2%
ceiling — and settled to 0.01% once WebKit finished reclaiming. The transient is
JavaScriptCore's `libpas` scavenger thread, not app-layer work: a 20-second
`sample` of the process while occluded put the main thread in `mach_msg2_trap`
for 17397 of 17398 samples. Do not chase this one without re-measuring settled.

Override the seed's URL set for a realistic run with `SOAK_URLS` (space-separated,
read by `seed`): `SOAK_URLS="https://a https://b" scripts/soak.sh seed`. The app
is now **Chord** — `scripts/soak.sh` drives and samples the `Chord` process, but
the profile still lives under the `Browser` Application Support folder (the rename
is display-only; bundle id `com.rizal.browser` is unchanged).


## Multiple windows, added 2026-07-27

Covers the three commits that split `WindowState` out of `TabStore`, turned
`Window` into `WindowGroup`, and made a tab draggable between windows.

Open a second window with **File ▸ New Window** before starting §B onward. Where a
check says "window A" and "window B", A is the one that launched.

### The bug this checklist found — one tab, one window

Keep this at the top: it is the failure mode multi-window invites, and it is
silent.

A `WKWebView` is an `NSView`, and an `NSView` has exactly one superview. A tab
selected in two windows renders in whichever drew last and leaves the other
**blank** — no crash, no log, just an empty content area with a perfectly working
sidebar. Three windows all landed on one tab and two of them were empty.

The DEBUG overlay (**⌃⌘P**) exists to make this visible: per window it shows the
window's identity, Space, selection, and **`also showing it`**. That last number
must stay **0**; anything higher is that many windows fighting over one web view.

Screenshots alone could not diagnose it — windows shuffle z-order between
captures, and a blank window looks exactly like one whose page has not loaded.
Turn the overlay on in every window before investigating anything here.

### A. Driven end-to-end on 2026-07-27

Exercised with `cliclick` against the real app. Still listed as checks because
they are worth repeating after any change to how a selection is assigned.

- [x] **⌘N** opens a second window. The keystroke *does* work — an earlier
      AppleScript `keystroke` probe failed to fire it and I wrongly suspected the
      binding. Distrust `osascript keystroke` for this; `cliclick` is reliable.
- [x] The second window **paints its content**. This genuinely failed first time
      — see above.
- [ ] **⌘⇧N** opens a new blank tab in the focused window (it moved off ⌘N).

### B. Per-window independence

A single cause — `claimWindow()` handing out the same object — would fail all of
these at once. Report them as one finding, not ten.

- [ ] ⌘S in window A collapses **only A's** sidebar
- [ ] Dragging A's sidebar edge resizes **only A**
- [ ] ⌘2 in A switches **only A's** Space; B stays where it is
- [ ] With A and B in different Spaces, each sidebar lists only its own Space's
      tabs, and the window tint differs
- [ ] Selecting a tab in A does not move B's selection
- [ ] ⌘F and a query in A leaves B's find bar closed and empty
- [ ] Collapsing the Pinned section in A leaves B's expanded (per-window *and*
      per-Space)

### C. Cross-window tab drag

**Aim at an actual drop target.** The empty area *below* the tab list is not one
— a drop there is silently ignored, which reads exactly like the drag being
broken. Drop onto the favourites row, a tab row, or the list itself.

- [ ] **Same Space**, A → B: the tab reorders and is selected in B, with **no
      dialog** (both windows show the same list)
- [ ] **Different Spaces**, A → B: prompts *"Move "<title>" to <Space>?"* with the
      separate-profile / signed-out warning
- [ ] Confirming: the tab appears in B, is selected there, and is gone from A.
      The page **reloads** — expected, it is a different cookie store
- [ ] Cancelling: nothing moves, the tab stays in A
- [ ] Dropping across Spaces into B's **favourites grid** lands it as a favourite,
      not a loose tab
- [ ] **Drag into B's content area** (drag-to-split) from another Space: same
      prompt; confirming makes it a second pane and consumes the source tab;
      cancelling leaves both tabs untouched
- [ ] Same-Space drag-to-split still merges immediately, no prompt

The split case is the one worth the most attention: it was unreachable across
Spaces before a second window existed, and without the prompt it would change a
page's data store silently.

### D. Menu commands act on the focused window

These moved from `NSApp.mainWindow` (a guess) to `@FocusedValue`.

- [ ] ⌘T / ⌘L with B focused: the command bar opens over **B** and its result
      lands in B
- [ ] ⌘Y (History) and ⌘, (Settings) present on the **focused** window
- [ ] ⌘W closes a tab in the focused window only
- [x] ⌘D (pin) and ⌘⇧D (split) act on the focused window's selected tab —
      driven 2026-07-27. With B focused, ⌘D pinned **B's** selected tab and left
      A's selection untouched; ⌘⇧D opened the Split command bar over **B** and
      the chosen tab became a second pane in B. Overlay `also showing it` stayed
      0 in both throughout.

### E. Regressions — one window must behave exactly as before

- [x] Closing the second window leaves the first fully working — driven
      2026-07-27. After closing B, A rendered, switched tabs, overlay clean
      (`windows open 1`, `also showing it 0`).
- [x] Quit and relaunch restores the session. **macOS restores the windows
      itself** — relaunch with two open and you get two back, even though Chord
      persists no layout of its own. (The note here used to say "expect one
      window"; that was wrong. Chord stores nothing, AppKit scene restoration
      does it.) What Chord does *not* restore is which Space or tab each had.
      Driven 2026-07-27: quit with two windows, relaunched, both came back and
      **both painted** (this is the blank-window bug's exact scenario) with
      distinct selections and `also showing it 0` in each.
- [x] Deleting a Space that B is sitting in **re-homes B** to a surviving Space
      instead of blanking it — driven 2026-07-27 with a *throwaway* Space (New
      Space → moved a window into it → Delete Space and Its Data). The window
      re-homed to a surviving Space with a valid selection and rendered content;
      `also showing it 0`. Use a throwaway Space for this — deleting a real one
      destroys its tabs and cookies permanently.
- [~] Two windows in different Spaces, each signed into a different Google
      account, stay signed in independently — the M2 done-when, now under two
      windows. Mechanism verified 2026-07-27: two windows showing `google.com`
      in different Spaces at the same time had **independent** login state (one
      logged in as the Personal account, a fresh Space's `google.com` showed
      "Sign in"). The literal two-*accounts* form needs a second real Google
      sign-in (credentials), so it is left to the operator; the per-Space data
      store isolation it rests on is what was checked here and holds across two
      windows.
- [ ] Extensions load and their toolbar actions work with two windows open —
      **not exercised 2026-07-27**: this profile has no extensions installed
      (`extensionEnablement` is empty, no manifests on disk), so there is
      nothing to load. Install an extension first, then re-run. Logic is
      unit-tested.

### Known limitations — expected, do not file

**Corrected 2026-07-31:** the three limitations that used to be listed here
(Little Chord landing in the first window, app-opened URLs likewise, and a
Space-button drag not prompting) were **fixed** in the post-multi-window batch —
the store now tracks the last-focused window, and a Space-button drop routes
through the same cross-Space prompt as every other path. Verify them as checks
rather than accepting them as limits:

- [ ] With B focused, a **Little Chord** panel promotes into **B**
- [ ] `open -a Chord https://example.com` with B focused opens in **B**
- [ ] Dragging a tab onto a **Space button** for a *different* Space prompts,
      exactly like a cross-Space drag into another window

Still true: with no window key at all, both fall back to the first window.

### Not worth doing by hand

- **The sweep skipping a tab that is visible in another window.** The shortest
  idle preset is 1 hour. Covered by `sweepSkipsTabsVisibleElsewhere`; the failure
  it guards against is a tab being archived out from under a window that is
  showing it.
- Window-close reconciliation — covered by tests, and windows are held weakly, so
  a stale entry compacts itself.

---

## Password vault (added 2026-07-31)

Save and fill are verified live on github.com; the rest of this list is what a
change to the vault should re-check. Use a throwaway account — never a real
password — since a failed sign-in is fine for exercising capture.

**Expect a login-keychain dialog the first time each new build reads a saved
password.** That is macOS noticing an ad-hoc rebuild, not a bug: click **Always
Allow**. See the design doc before trying to "fix" it with signing.

### Save

- [x] Signing in offers **Save password?** with Save / Not Now / Never
      (verified live 2026-07-31 on github.com)
- [x] **Not Now** saves nothing (`SELECT COUNT(*) FROM credential` stays 0)
- [ ] **Save** stores it; Settings → Passwords lists it
- [ ] Signing in again with the **same** password offers nothing
- [ ] Signing in with a **changed** password offers **Update**, and does not
      create a second entry
- [ ] **Never** silences the site; it appears under Settings → Passwords →
      Never Saved, and **Ask Again** un-silences it
- [ ] A **multi-step** login (Google: email page, then password page) saves with
      the username from the *first* step, not blank

### Fill

- [x] A **key button** appears in the sidebar next to reload, only on a page with
      a saved login (verified live 2026-07-31)
- [x] Clicking it fills the form (verified live)
- [ ] With **two** accounts saved for one site, the key opens a menu and the
      chosen account is the one filled
- [ ] Nothing fills on page load or on focus — only on the click
- [ ] After filling, submitting actually signs in (the values are really in the
      form, not just painted into it)
- [ ] The key does **not** appear on a site with nothing saved, nor on a page
      with no login form

### Manage

- [ ] Settings → Passwords lists site, account, and last use
- [ ] **Reveal** prompts for Touch ID and then shows the password; cancelling
      shows nothing
- [ ] **Trash** deletes it after a confirmation, and it disappears from the list
- [ ] A deleted credential no longer offers to fill on its site

### Refusals — none of these may fill

- [ ] A saved password is **not** offered on a subdomain
      (`https://sub.example.com` for something saved at `https://example.com`)
- [ ] Nor on plain **http://**
- [ ] Nor after the page navigates elsewhere between the offer and the click

## Site permissions — camera, microphone, notifications (added 2026-07-31)

None of this is reachable from `swift test`: the media path needs entitlements
and a real TCC grant, and notifications need the OS permission. It has to be
driven by hand. See ADR 014 / ADR 015.

**Do this in a throwaway Space where practical**, and remember there are two
layers: Chord's per-site decision, and macOS's per-app grant in System Settings →
Privacy & Security. A site allowed in Chord with the app denied in macOS gets
nothing, and that is the expected behaviour, not a bug.

### Camera and microphone

- [ ] A site calling `getUserMedia` (Google Meet, `webcamtests.com`) prompts
      **once**, naming the host, with camera and microphone in one sheet when it
      asks for both
- [ ] **Allow** → capture starts. macOS's own TCC prompt appears the first time
      for the app as a whole
- [ ] Revisiting the same site in the same Space **does not prompt again**
- [ ] Quit and relaunch → still no prompt (the decision is on disk, not in memory)
- [ ] The **same site in another Space prompts again** — this is the property the
      per-Space scoping exists for
- [ ] **Deny** → the page's promise rejects and the site shows its own error;
      revisiting does not re-prompt
- [ ] Settings → Privacy & Data → **Site Permissions** lists the decision with the
      Space name; **×** removes it and the site asks again next time
- [ ] **Release build**: the microphone actually works. This is a separate check
      from Debug — Hardened Runtime is only on in Release and needs
      `com.apple.security.device.audio-input`. A green camera and a dead mic is
      the exact signature of that key going missing

### Notifications

- [ ] A site calling `Notification.requestPermission()` (`bennish.net`) prompts
      once; **Allow** → a banner appears in Notification Center
- [ ] Clicking the banner **focuses the tab that posted it** and runs the page's
      `onclick`
- [ ] Reloading the page does **not** re-prompt, and `Notification.permission`
      reads `granted` immediately (the shim queries the stored decision at load —
      this is the fix for Slack re-asking on every visit)
- [ ] A second site prompts on its own behalf
- [ ] Notifications from a **backgrounded/occluded** tab still arrive
- [ ] Closing the tab stops delivery — expected, this is not Web Push

## Extension popups vs. the collapsed sidebar (added 2026-07-31)

The popup is anchored to the sidebar-header button, so anything that removes the
sidebar removes the popup. Regression-tested in `ExtensionPopupSidebarTests`, but
the AppKit half only exists in the real app.

- [x] With the sidebar **collapsed**, reveal it, click an extension's toolbar
      button, then **move the pointer into the popup** — the sidebar stays put and
      the popup stays open (verified live 2026-07-31; before the fix it vanished
      the instant the pointer left the sidebar)
- [ ] Closing the popup lets the sidebar auto-hide again a moment later
- [ ] Clicking the page, or `Esc`, still dismisses the popup
- [ ] With the sidebar **docked**, the popup behaves as before
- [ ] With two windows open, a popup in window B does **not** pin window A's
      sidebar (the notification is filtered on window identity)

## User-Agent setting (added 2026-07-31)

- [ ] Settings → General → User Agent offers Default / Chrome / Firefox /
      Safari-iPhone / Custom; picking Custom pre-fills the current UA
- [ ] `postman-echo.com/get` (or `whatismybrowser.com`) reports the chosen string
      after a reload — the setting takes effect on the **next load**, not live
- [ ] Safari — iPhone gives a phone layout on a site that serves one
- [ ] An emptied custom field falls back to the default rather than sending blank
- [ ] **Default** UA is byte-identical to Safari's (`…Version/XX.Y
      Safari/605.1.15`). If a site misbehaves, check this before blaming anything
      else — **Google Meet fails under the Firefox UA** with "Couldn't start video
      call", which reads as a permissions bug and is not one

## YouTube ad skipping (added 2026-07-31)

Best-effort by design (ADR 013) — YouTube changes its page constantly, so a miss
here is a selector to update, not a regression in the browser.

- [ ] A video with a **skippable** pre-roll: the ad is skipped essentially
      immediately, no click needed
- [ ] An **unskippable** ad clears in a fraction of a second (the playback-rate
      blast, not just a seek)
- [ ] After the ad, the content video plays at **1× speed** — the shared `<video>`
      makes a leaked playback rate the failure mode to watch for
- [ ] Masthead / promoted rows / in-feed ad slots are gone from the home feed
- [ ] **YouTube Music** ad slots are hidden and audio ads are skipped
- [ ] Per-tab **mute** still behaves independently — the ad blocker never mutes

## Media / codecs (diagnostic, not a pass-fail)

- [ ] `Cmd+Ctrl+P` (DEBUG) reports per-codec `hw`/`sw`/`no` for the active tab.
      Expected today: **AV1 `sw`**, VP9 / HEVC / H.264 `hw`. If AV1 ever reads
      `hw` on a future macOS, YouTube should start serving AV1 and the Reels
      softness should go — worth re-checking after an OS update

## Private windows (added 2026-07-31)

⌘⇧N. Every item below was checked in the real app when the feature landed; the
`sqlite3` ones are the point of the feature, so re-run them after touching any
persistence path.

- [x] File ▸ **New Private Window** exists and its key equivalents are right —
      New Window ⌘N, New Private Window ⌘⇧N, New Blank Tab ⌘⌥N (read back from
      `AXMenuItemCmdChar` / `AXMenuItemCmdModifiers`; the ⌘⇧N *keystroke* is not
      synthesizable, same as ⌘N — see the multi-window notes)
- [x] The private window's sidebar has **no Space switcher, no favourites, no
      Pinned section**, and shows the "Private window" footer with its honest
      copy
- [x] **Signed out**: Google in the private window offers "Sign in" while a
      normal window is signed into the same account — the `.nonPersistent()`
      store, live
- [x] The private Space appears in **no other window's** Space switcher
- [x] Nothing on disk, checked while the window was open:
      `select count(*) from space where isPrivate=1` → **0**,
      no `pane` row for the private page, no `historyEntry` for it, and
      `windowLayout` counts only the normal windows
- [x] Closing the private window leaves every other window **painting**, with
      the switcher unchanged
- [ ] Quit with a private window open, relaunch → only the normal windows come
      back. Not re-run by hand; nothing private is on disk (above), and the
      restore-side filter is unit-tested
- [ ] A sign-in in a private window raises **no save bar**, while the fill key
      still works (unit-tested; not driven live)

## Link context menu (added 2026-07-31)

Driven live on 2026-08-01.

- [x] Right-click a link → **Open Link in New Tab**, **Open Link in New Private
      Window**, **Open in Little Chord**, then a separator, above WebKit's own items
- [ ] Right-click on a *non-link* → none of the three appear (not re-checked; the
      visibility test is WebKit's own menu-item identifiers, unchanged since
      Little Chord shipped)
- [x] Open Link in New Tab lands in **the same window**, in the **background**
      (you stay on the page you were reading). **Check the DB, not the sidebar**:
      if the current page is a favourite it renders in the grid, and a background
      tab has no title or favicon until it is selected — that combination looks
      like nothing happened
- [ ] The same item inside a private window keeps the link **in that private
      window** (unit-tested; not driven)
- [x] Open Link in New Private Window opens **the link**, not the new-tab page
