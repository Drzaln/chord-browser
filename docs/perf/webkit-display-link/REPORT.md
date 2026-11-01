# Suspended hidden page leaves the UI process's display link firing (macOS)

**Component:** WebKit2 / Process model, Layout and Rendering (RemoteLayerTree)
**Version:** macOS 27.2 (system WebKit)

## Summary

When a hidden page's web process is suspended (WKPreferences
`inactiveSchedulingPolicy = .suspend`, or `.throttle`, which on macOS 27 also
gets suspended), the UI process can be left calling
`RemoteLayerTreeDrawingAreaProxyMac::didRefreshDisplay` on every display
refresh (~120 Hz on ProMotion) for that page until the web process next runs.
Each further brief wake of the suspended page (a script evaluation, a window
activity-state change) re-arms it. With several hidden pages the UI process
takes hundreds of wakeups per second while idle.

## Steps to reproduce

`repro.swift` (attached, in this folder; `swiftc -O repro.swift -o repro && ./repro suspend`):
one window, five WKWebViews each on its own site, four of them `isHidden`
(background tabs), `inactiveSchedulingPolicy = .suspend`. Every 60 s the
window changes state, alternately minimized and restored, and the app hidden
and unhidden (as a user switching apps would). The program prints the UI
process's wakeups per second (proc_pid_rusage interrupt + package idle
wakeups) every 10 s. `./repro none` is the same with `.none`.

## Results

MacBook Pro (ProMotion), macOS 27.2, UI process wakeups/s:

| t | event | `.suspend` | `.none` |
|---|---|---:|---:|
| 0-60 s | idle (the hidden pages suspend) | 0.1-1.7 | 0.3-3.1 |
| 60 s | minimize + restore | 40 then 0.1-0.8 | 33 then 0.1-1.5 |
| 120 s | hide + unhide app | **451, then 621-626 for the whole minute** | 24 then 0.1-1.5 |
| 180 s | minimize + restore | 46 then 0.1-0.8 (stops) | 33 then 0.1-1.5 |
| 240 s | hide + unhide app | **453, then 624-627** | 24 then 0.1-1.5 |
| 300 s | minimize + restore | 55 then 0.1-0.3 (stops) | 34 then 0.1-1.5 |
| 360 s | hide + unhide app | 32 then 0.1-0.3 (not this time) | 24 then 0.1 |

~625/s is the 120 Hz display link for the four hidden pages (plus the
visible one's idle). It runs until the next activity-state change happens to
let the pages commit. The log shows `sendPrepareToSuspend` and
`hideContentUntilPendingUpdate` for the hidden pages' processes around each
spin.

## Expected

Once a hidden page's process is suspended, the UI process stops observing the
display for it; a later brief wake doesn't leave a display link running.

## Analysis

`WebProcessProxy::sendPrepareToSuspend` calls
`WebPageProxy::hideContentUntilPendingUpdate` on each page, which (through
`RemoteLayerTreeDrawingAreaProxy`) sends `DispatchAfterEnsuringDrawing` and
forces a rendering update. When the process is suspended before that commit
arrives, the drawing area keeps a pending `DisplayDidRefresh` and its
DisplayLink observer stays registered, firing every frame until the web
process runs again and commits. In Chord (a WKWebView browser) with seven
parked tabs we measured 580-860 UI wakeups/s; an lldb breakpoint on
`RemoteLayerTreeDrawingAreaProxyMac::didRefreshDisplay` showed seven drawing
areas firing each frame, exactly the parked tabs, and the log shows
`hideContentUntilPendingUpdate` without a matching completion.
