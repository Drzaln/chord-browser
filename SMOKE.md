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

### 30-minute soak
- [ ] 20 tabs open, cycle through them repeatedly for 30 minutes
- [ ] Record footprint at start and end (debug overlay, `Cmd+Ctrl+P`)
- [ ] Growth over the soak means a leak — investigate before moving on

Start: ______ MB   End: ______ MB
