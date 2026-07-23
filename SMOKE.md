# Manual smoke checklist

Run before calling a milestone done. Add to it as features land; never delete a
check that still applies.

## Build gate

```bash
./scripts/prepush.sh
```

Builds all packages, runs all tests, and builds the app — warnings as errors.

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

| Metric | Target | Ceiling | Measured | |
|---|---|---|---|---|
| App process footprint | < 150 MB | 250 MB | **59–72 MB** | pass |
| Total footprint | < 1.2 GB | 1.8 GB | **654–775 MB** | pass |
| Idle CPU, visible | < 0.5% | 1% | **0.36%** app | pass |
| Idle CPU, occluded | ~0% | 0.2% | **0.01%** app | pass |
| Cold launch | < 400 ms | 800 ms | **< 308 ms** | pass |
| Space switch | < 100 ms | 200 ms | **< 1 ms** | pass |
| Command bar open | < 50 ms | 100 ms | **6–27 ms** | pass |
| Sidebar scroll | 120 fps | no drops at 60 | not measurable | — |

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

## M2 — Spaces

### Switching
- [ ] The Space strip appears at the top of the sidebar
- [ ] Clicking a Space switches the tab list to that Space's tabs
- [ ] `Cmd+1`…`Cmd+9` select Spaces by position
- [ ] A shortcut for a Space that does not exist does nothing
- [ ] Switching back to a Space returns to the tab you were last on
- [ ] Switching to an empty Space opens a new tab in it
- [x] The sidebar gradient changes with the active Space (the *animation*
      itself still needs an eye — stills cannot show it)
- [ ] Reduce Motion collapses the animation without breaking the switch

### Isolation — the M2 done-when
- [ ] Log into Google in Space A
- [ ] Switch to Space B, open the same site: **you are logged out there**
- [ ] Log into a *second* Google account in Space B
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
- [x] An open tab in *another* Space is findable, and its row names the Space
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
- [x] Clicking an unfocused pane focuses it *and* the click still reaches the
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
- [ ] Browsing inside the panel and *then* promoting keeps where you got to

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
below had passed its *behavioural* check for two milestones while never once
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

Still not covered, and still needing a human: the gradient *animation* and
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
      "Switch to Tab" *before* you press it

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
> `interactionState` is written on tab *deactivation*, on occlusion, and on
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
- [ ] Switch tabs, then force-quit: the tab you switched *away* from restores,
      the one you were looking at may not
- [ ] Closing a tab drops its stored state (count above goes down after a save)

### Downloads
- [x] A link to a non-renderable file downloads instead of doing nothing
- [x] The file lands in ~/Downloads and is byte-for-byte correct (verified in the
      real sandboxed app — `swift test` runs unsandboxed and cannot prove this)
- [x] A second download of the same name becomes `name-1`, it does not overwrite
- [ ] The progress bar advances on a large, slow download
- [ ] A download with no `Content-Length` shows an indeterminate bar, not 0%
- [ ] Cancel actually stops the transfer
- [ ] Clearing a finished row leaves the file on disk
- [ ] The downloads button is hidden until there is something to show

## M6 — Polish

### Collapsible sidebar (§4.1)

Verified 2026-07-23 by driving the app. The state is readable without a
screenshot: sample a pixel that is sidebar when expanded and page when
collapsed (`screencapture -x -R750,350,4,4`), which is how the launch
determinism below was checked cheaply.

- [x] `Cmd+S` and the sidebar button both collapse and expand it
- [x] Collapsed shows favicons only, Space icons stacked, no address field
- [x] **Hovering the rail expands it over the page without shifting web
      content** — the page's logo and search box stay at identical screen
      coordinates
- [x] Leaving re-collapses it, after a delay, and re-entering cancels that
- [x] **The traffic lights are hidden in the rail** and return on expand. They
      do not fit 48 points: before this the zoom button sat on the web content
- [x] The collapsed state survives relaunch — 5 of 5 launches, checked because
      one earlier launch came up expanded and a race here would be a real bug.
      Not reproduced since; if it returns, suspect `WindowAccessor` reporting a
      window before the scene has one
- [x] Drag-to-split still works from the hover-expanded sidebar
- [ ] Reduce Motion collapses the animation to a cross-fade

### 30-minute soak
- [x] 20 tabs open, cycle through them repeatedly for 30 minutes
- [x] Record footprint at start and end (debug overlay, `Cmd+Ctrl+P`)
- [x] Growth over the soak means a leak — investigate before moving on

Start: **70** MB   End: **62** MB

Run 2026-07-23 on Apple Silicon: 3 Spaces, 22 tabs, 12 live web views (the pool
cap), Space switched every 4 s for 30 minutes, sampled every 60 s.

| | start | end | range |
|---|---|---|---|
| App `phys_footprint` | 70 MB | 62 MB | 59–72 MB |
| App + all WebKit helpers | 720 MB | 727 MB | 654–775 MB |
| Live web views | 12 | 12 | 12 throughout |

No growth over 30 minutes — the app process finished *lower* than it started,
and the total oscillates around a flat mean. No leak signal.

#### M5 re-run, 2026-07-23

§8 gates every milestone on this, and the run above predates split view and
Little Arc — both of which add live web views (a 4-pane tab is 4 at once).
Re-run with `scripts/soak.sh`, which did not exist before and is why the soak
had been run exactly once: `seed` writes the fixture, `run` drives and samples.

3 Spaces, 21 tabs (one per Space is a 4-pane split), 12 live web views, Space
switched every 4 s for 30 minutes, sampled every 60 s. Started from a
*restored* session, so lazy restore is on the path.

| | start | end | range |
|---|---|---|---|
| App `phys_footprint` | 60 MB | 58 MB | 58–60 MB |
| App + all WebKit helpers | 555 MB | 498 MB | 497–555 MB |
| Live web views | 12 | 12 | 12 throughout |

| §6.1 budget | measured | target | ceiling |
|---|---|---|---|
| App RSS | 58 MB | < 150 MB | 250 MB |
| Total footprint | 498 MB | < 1.2 GB | 1.8 GB |
| Idle CPU, visible | 0.083% | < 0.5% | 1% |
| Idle CPU, occluded | 0.006% | ~0% | 0.2% |

No leak: both figures end *below* where they started, the total declining
monotonically as WebKit reclaims. Split view costs nothing structural — a
4-pane tab is four panes against the same 12-view cap, not four extra.

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
