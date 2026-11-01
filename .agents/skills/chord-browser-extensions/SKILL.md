---
name: chord-browser-extensions
description: How Chord runs Chrome extensions on WKWebExtension, and how to change, test and debug that code. Covers the per-Space controller, the prepared bundle and the Chrome compatibility shim (ExtensionShimScript), the shim's native ports (chord, chord.keepalive, chord.events, chord.socket), offscreen documents, worker holds, popups, capture and the recording pill, script errors, and the test patterns for extension code. Use when touching Packages/Sources/ChordExtensions, when an extension misbehaves (popup spins, does nothing, no sound, worker restarts), or when writing extension tests.
---

# Chord extensions

`ChordExtensions` (≈30 files, ≈11k lines) hosts Chrome MV3 extensions on
Apple's `WKWebExtension` runtime and fills the gaps between what Chrome
extensions use and what WebKit implements. Read the architecture skill for
where it sits; this skill is for working inside it. History and the M8/M9
compatibility matrix are in CHECKPOINT.md (dated M8/M9 sections).

## Shape

- **One `WKWebExtensionController` per Space** (ADR 011), built in
  `WebKitExtensionHost`. Extensions load per Space; a context is
  `loadedContexts[spaceID][slug]`. The app sees only `ExtensionHost` (a
  protocol, WebKit-free at its surface); **every new member gets a no-op
  default** in the protocol extension so fakes keep compiling.
- **Tabs** reach WebKit through `ExtensionTabModel` (implemented by
  `TabStore`) and `PaneWebViewProviding` (the engine). The store calls
  `extensionTabDidOpen/Activate/Close`; `ExtensionAdapters` presents a Space
  as a `WKWebExtensionWindow`. A content script's `runtime.sendMessage`
  fails with "Tab not found" if WebKit doesn't know its tab.
- **Install**: `Crx` (store download) → `ExtensionArchive`/`ExtensionBundle`
  (verify, unpack; ADR 017) → `ExtensionInstaller` → `ExtensionShims.prepare`
  (the prepared copy WebKit loads) → `ExtensionConsent` (the one question).
- **Prepared bundle** (`ExtensionShims`): Chord rewrites an unpacked copy —
  prepends the shim to the worker and pages, adjusts the manifest — and
  stamps it (`stampValue(workerGeneration:)`, includes the shim's
  `fingerprint`). Any change to `ExtensionShimScript` changes the fingerprint,
  so installs re-prepare on next load. Line numbers WebKit reports are offset
  by the prepended shim (`ExtensionShims.workerShimLines`).

## The shim (`ExtensionShimScript.swift`)

One JavaScript file, run in the worker and in every extension page, that
supplies Chrome APIs WebKit lacks (offscreen, bookmarks, history, downloads,
tabGroups via folders, sidePanel fallback, identity, desktopCapture, …) and
works around WebKit behaviour. It calls the browser through native messaging
to application `chord`, answered in-process by `ExtensionShimBroker.answer`
(`{api, args}` → `{value}` / `{error}`) — no external host. Long-lived ports:

| Port | Swift side | Purpose |
|---|---|---|
| `chord` | `ExtensionShimBroker` | request/response API calls |
| `chord.keepalive` | `ExtensionKeepAlive` | worker holds (below) |
| `chord.events` | `ExtensionEvents` | browser → worker pushes (e.g. tabGroups changed) instead of polling |
| `chord.socket` | `ExtensionSocket` | a worker's WebSocket, made by the browser (WebKit's in-worker WebSocket deadlocks the main thread) |

Rules: the shim hides its own messages (`__chordPing`, `__chordCall`,
`__chordNative` words) from extension listeners; never poll on a timer in
the shim — wait for an event (`ShimPerfBudgetTests` holds the line).

## Workers and holds

WebKit unloads an idle worker after ~30 s and starts it in a new web process
on the next event. `ExtensionKeepAlive` holds a worker that started again
within 150 s: 600 s holds, a ping every 20 s from one hidden page of the
extension (`KeepAlivePinger`; a native port's traffic doesn't reset WebKit's
idle clock, an event does). The shim says `woke` on the port when an alarm or
a non-ping message reaches the worker; a hold ending within 150 s of that is
renewed. Log lines: `holding worker …`, `… again: still being woken`,
`let go of worker …`. `ExtensionWorkerRecovery` re-points ports after a
worker restarts.

## Pages: popups, offscreen, popouts

- **Scheduling policy**: extension pages use `.throttle`, never `.suspend`;
  AUDIO_PLAYBACK offscreen documents use `.none`. A suspended page can leave
  the UI running a display link (WebKit bug, `docs/perf/webkit-display-link/`).
- **Offscreen** (`ExtensionOffscreen`): a windowless `WKWebView` registered as
  a tab (`context.didOpenTab`) so content scripts in its frames resolve.
  AUDIO_PLAYBACK documents sit in a never-shown `OffscreenWindow`: WebKit
  won't load or play media for a view that isn't in a window. USER_MEDIA ones
  turn off `getUserMediaRequiresFocus`.
- **Popup** (`ExtensionPopup`) is a popover that holds the sidebar open
  (AGENTS.md invariant 7d). **Popouts** (`ExtensionPopoutWindow`) for
  `windows.create({type: "popup"})`; **auth** (`ExtensionAuthWindow`) for
  `identity.launchWebAuthFlow`.

## Capture, recordings, script errors

- `ExtensionCapture`: `desktopCapture`/`getDisplayMedia` through the Mac's
  picker (no tab capture on WebKit). It KVOs camera/microphone and the private
  `_displayCaptureState` on extension pages (string keys, by name) and reports
  `ExtensionRecording`s → `TabStore.extensionRecordings` →
  `ExtensionRecordingPill` with Stop (`_setDisplayCaptureState:` etc.).
- `ExtensionScriptErrorLog`: WebKit's context errors with code 7 (Safari 27
  runtime: uncaught exceptions / unhandled rejections), deduplicated with
  counts, shim lines subtracted; shown in Settings → Extensions.

## Testing extension code

Patterns already in `Packages/Tests/ChordExtensionsTests` (copy them):

- **Load a test extension**: write `manifest.json` + files to a temp dir,
  `ExtensionShims.prepare(dir, fresh: true)`, then
  `WebKitExtensionHost().load(InstalledExtension(slug:identifier:resourceURL:), in: Space(...))`
  with a 32-letter `a`–`p` identifier; `context.loadBackgroundContent()` for
  the worker (`ExtensionKeepAliveTests`).
- **An extension page to run script in**: create an offscreen document via
  `ExtensionShimBroker.answer(["api": "offscreen.createDocument", ...])`, then
  `ExtensionOffscreen.webView(identifier:spaceID:)` and `callAsyncJavaScript`
  in `.page` (`ExtensionDNRTransformTests`).
- **A tab with content scripts**: `WebKitEngine` with
  `extensionControllerProvider = host`, `engine.surface(for: pane, in: space)`,
  `host.setAllHostsAccess(true, ...)`; for messaging also a one-tab
  `ExtensionTabModel` fake, `host.paneWebViewProvider = engine`,
  `host.extensionTabDidOpen` (`ExtensionMediaGestureTests`). Serve pages with
  `ChordTestSupport.TestHTTPServer`.
- **User gestures**: `el.click()` is not one. Put the web view in an
  `NSWindow` and call `web.mouseDown(with:)`/`mouseUp(with:)` with
  `NSEvent.mouseEvent` (`window.sendEvent` doesn't reach it under `swift test`).
- **Fakes for capture**: `navigator.mediaDevices` is absent under `swift
  test`; subclass `WKWebView` and drive the KVO keys (`ExtensionRecordingTests`).
- **Real store extensions**: `CHORD_REAL_EXTENSIONS=1 swift test --filter
  RealExtensionProbe` (network; skipped in prepush).
- Make a new test fail without the fix once before trusting it.

## Debugging an extension

1. Settings → Extensions: "N script errors" under it? Read them first.
2. Context errors in the log (`Log.extensions`, mirrored to
   `Application Support/Chord/Logs/chord.log`): code 6 = background failed to
   load (often an API WebKit drops, e.g. a permission it doesn't implement —
   the shim must supply it); code 7 = script errors.
3. Worker churn: grep the log for `holding worker` / `let go`; count
   WebContent launches (`log show … WebProcessProxy::didFinishLaunching`).
4. No sound / media never starts: is the page's view in a window?
5. Spinning popup: the worker probably died at startup (step 2). Also know
   that WebKit drops what a worker posts on a port it has only just opened
   (the shim's WebSocket re-sends its opening until answered for that reason).
6. Develop menu (Developer Mode) → Web Inspector on the extension's pages.

See also the maintenance skill ("An extension loads but does nothing") and
CHECKPOINT's M8/M9 sections for per-extension notes (Bitwarden, 1Password,
uBlock Lite, Tampermonkey, Loom).
