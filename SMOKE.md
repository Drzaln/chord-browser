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
- [ ] Reload works; the button becomes Stop mid-load and cancels
- [ ] Progress bar appears during load and disappears on completion

### Tabs
- [ ] `Cmd+T` opens a new tab and selects it
- [ ] `Cmd+W` closes the current tab and selects a neighbour
- [ ] Closing the last tab opens a fresh one rather than an empty window
- [ ] Clicking a sidebar row switches tabs; the web view does not reload
- [ ] Title updates in the sidebar as pages load
- [ ] Favicon appears in the sidebar, falling back to a globe when absent
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
- [ ] Cold launch to first interactive frame < 400 ms
- [ ] Idle CPU with the window visible and nothing loading < 0.5%
- [ ] Idle CPU with the window minimised ~0%
- [ ] App RSS with 20 tabs / 5 live < 150 MB
- [ ] Sidebar scroll stays at display refresh with 20 tabs

## M2 — Spaces

### Switching
- [ ] The Space strip appears at the top of the sidebar
- [ ] Clicking a Space switches the tab list to that Space's tabs
- [ ] `Cmd+1`…`Cmd+9` select Spaces by position
- [ ] A shortcut for a Space that does not exist does nothing
- [ ] Switching back to a Space returns to the tab you were last on
- [ ] Switching to an empty Space opens a new tab in it
- [ ] The sidebar gradient changes with the active Space, and animates
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
- [ ] The bar is visually centred and legible over the window
- [ ] The app behind it does not visibly activate or lose its selection
- [ ] Typing filters with no perceptible lag
- [ ] Up/down arrows move the highlight and wrap at the ends
- [ ] An open tab in *another* Space is findable, and selecting it switches Space
- [ ] Commands ("new space", "close tab") are reachable by name

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

### 30-minute soak
- [ ] 20 tabs open, cycle through them repeatedly for 30 minutes
- [ ] Record footprint at start and end (debug overlay, `Cmd+Ctrl+P`)
- [ ] Growth over the soak means a leak — investigate before moving on

Start: ______ MB   End: ______ MB
