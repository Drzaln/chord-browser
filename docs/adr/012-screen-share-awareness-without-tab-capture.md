# 012 — Screen-share awareness by user script, not tab capture

**Status:** accepted

Sites like Google Meet and Discord call `navigator.mediaDevices.getDisplayMedia()`
to share the screen. On WebKit the OS picker offers **Entire screen** and a
**Window** list, but never **This tab** — tab-level capture is a Chromium-only
display surface, and the public WebKit SDK exposes no equivalent. So Chord does
**not** try to add "Share this tab."

Faking it would mean capturing our own window with ScreenCaptureKit, cropping to
the web view, and piping `CMSampleBuffer` frames back into the page's own
JavaScript `RTCPeerConnection`. There is no bridge for that last step: the only
in-page sink is `canvas.captureStream()`, fed frame-by-frame over a local socket
— software-encoding every frame, shipping it, decoding, blitting, then
re-encoding for WebRTC. For a live call that is worse than just sharing the
window. Rejected.

What we do instead is make **window** sharing good:

- **Presentation mode** (`WindowState.isPresentationMode`) hides the sidebar and
  all chrome so a shared window shows only the page. The traffic lights stay, so
  the mode is never a trap.
- The **window title** is kept in step with the active page even though
  `.hiddenTitleBar` hides it visually — it is still the label the screen-share
  picker and Mission Control show, so the right window is findable.
- A **"Sharing this window" banner** with a one-click Stop.

The banner needs to know when a page is sharing, and WebKit reports nothing. So,
exactly as `MediaActivityMonitor` does for audio (see ADR 008), `ScreenShareMonitor`
observes from inside the page: a user script wraps `getDisplayMedia`, calls
through to the real implementation (it never intercepts the media — the site's
WebRTC path is untouched), and posts `{ sharing: bool }` when the first stream
starts and the last one ends. It also exposes `window.__chordStopSharing()` so
the native Stop button can end capture by calling `track.stop()` on every
display track.

The state flows engine → `PaneSnapshot.isScreenSharing` → `PaneRuntime` →
`RootView`'s banner, the same path audio playback takes. Like the audio handler,
the message handler is a per-view leak source (6.7) and is removed explicitly in
`LiveWebView.tearDown()`; it is installed on the per-view content controller, not
the shared configuration template, for the same `copy()` reason ADR 008 records.

Trade-off: `track.stop()` does not fire the `ended` event — by spec that event
only fires when a track ends for a reason *other* than the caller stopping it. A
site like Meet drives its "Presenting" UI off `track.onended`, so stopping the
track alone leaves Meet still showing "Presenting". The stop hook therefore also
`dispatchEvent(new Event('ended'))` on each track (and `'inactive'` on the
stream) so the site's own listener runs, exactly as a native "Stop sharing"
would. And it posts `sharing:false` itself rather than waiting for our listener.
If a page holds multiple display streams, the banner clears only once the last
one ends.

The tracked streams and the stop hook are pinned to a single `window.__chordShare`
singleton, not a per-injection closure. `atDocumentStart` can run more than once
against the same document (re-injection, `about:blank` handovers), and the first
cut of this shipped without a guard: a second run rebound `original` to our own
wrapper and redefined `__chordStopSharing` over a fresh, empty `active`. Stop then
iterated nothing — it posted `sharing:false`, so the banner vanished, but no track
was actually stopped and the site kept sharing. The singleton makes the one
override and the one stop hook share the same stream list for the window's life.

The banner deliberately does **not** name the shared surface. `getDisplayMedia`
can capture a whole screen, this window, or another app's window, and WebKit
reports which to neither the app nor reliably to the page — so the banner says
"This page is sharing your screen," a claim that holds whatever was picked, rather
than "this window," which is usually wrong.
