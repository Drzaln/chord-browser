# 019 — the web view is laid out by frame, not Auto Layout, so element fullscreen survives WebKit's reparenting

**Status:** accepted (post-M7, shipped 2026-08-11)

## Context

Sometimes the YouTube player went **fully black** when entering video fullscreen
(the player's own fullscreen button). Esc/F exited to a normal page, but
re-entering fullscreen was black again, and only **quitting the app** fixed it —
reloading the tab did nothing, because it was not a page bug.

Two facts pin it down:

- **`WKWebView.fullscreenState` is documented KVO:** "When an element in the
  WKWebView enters fullscreen, WebKit will replace the WKWebView in the
  application view hierarchy with a 'placeholder' view, and move the WKWebView
  into a fullscreen window. When the element exits fullscreen later, the
  WKWebView will be moved back into the application view hierarchy. An
  application may need to adjust/restore its native UI components when the
  fullscreen state changes."
- **webkit.org/b/313802** (NEW, reproduced on macOS 26): when the `WKWebView`
  is AutoLayout-governed from an ancestor (which is what SwiftUI's
  `_NSHostingView` does), the move is fatal. `_saveConstraintsOf:` captures only
  constraints stored on the *immediate* superview and filters out
  `NSAutoresizingMaskLayoutConstraint`; `_replaceView:with:` swaps back a
  placeholder using `frame` + `autoresizingMask` only. A web view whose size
  lives in higher-ancestor constraints comes back at a collapsed `0×0` frame,
  the `:fullscreen` element sizes against a zero viewport, and the video renders
  black — persistently, because the wedged state survives page reloads and only
  a process restart clears it.

## Decision

**Layout the `WKWebView` inside its container with a frame and an autoresizing
mask, never Auto Layout.** This is the workaround the WebKit bug report
documents.

- `WebSurfaceContainerView.install(_:)` sets `translatesAutoresizingMaskIntoConstraints
  = true`, `autoresizingMask = [.width, .height]`, and `frame = bounds`. A
  full-bleed fill is the only layout the web surface ever had, so this is
  visually and functionally identical — the container is still the view SwiftUI
  sizes, and the rounded-corner clip stays on the container.
- `LiveWebView` additionally **KVO-observes `fullscreenState`** and, on
  `.notInFullscreen`, re-anchors the view to the container's bounds and forces a
  repaint — the "adjust/restore your native UI" the header asks for. Every
  transition is logged, so a recurrence can be tied to the mechanism.

## Consequences

- **Video fullscreen now renders.** Verified live by the user (2026-08-11);
  black fullscreen no longer reproduces.
- **No layout regression.** Split view, sidebar collapse/reveal, window resize,
  and popup panes all fill their containers exactly as before; autoresizing is
  marginally cheaper than a constraint pass.
- **The workaround is permanent and safe.** It stays a valid layout after Apple
  fixes 313802 upstream; the re-anchor is a no-op when the frame already matches.
- **A future overlay on the web page must not add constraints to the web view.**
  `translatesAutoresizingMaskIntoConstraints` is now true, so mixing in explicit
  constraints would conflict. Put overlays on the container — which is where the
  opaque-`AnyWebSurface` design says they belong anyway.
- **Recurrence is diagnosable.** If an OS/WebKit update regresses fullscreen,
  the AppLog line `re-anchoring web view for pane …` fires only when the frame
  was actually displaced.
