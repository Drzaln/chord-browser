# 022 — Linux port: Swift core + Rust GTK4 shell

**Status:** accepted (planned) — resolves the "make Chord run on Linux" open
question.

Chord is a macOS-only WebKit app (AppKit/SwiftUI/WKWebView). Linux has no
AppKit, no SwiftUI, and no WKWebView; its native WebKit is WebKitGTK behind a
GTK4 UI. A "port" is therefore a **second implementation sharing a core**, not
a recompile. This ADR fixes the strategy and the boundary that makes it cheap.

## Decisions

### 1. Shared Swift core, per-platform shells (the Arc/Dia model)

The codebase already isolates WebKit behind a `WebEngine` seam, but the seam is
macOS-shaped (`AnyWebSurface`, `WKWebsiteDataStore` semantics, PiP,
`NSPrintOperation`). We split the world along the seam:

- **Shared, platform-neutral:** `ChordCore`, `ChordPersistence` (GRDB runs on
  Linux), and `ChordStore` (its imports become protocols, its logic unchanged).
- **macOS-only (existing code, moved not rewritten):** `ChordEngine` →
  `ChordEngineApple` (the WebKit engine + its 27 files), `ChordExtensions`,
  `ChordUI` → `ChordUIApple`, `ChordSecrets`/`ChordCrypto` macOS impls,
  `ChordUpdater`, the `ChordApp` shell. `Chord.xcodeproj` untouched.
- **Linux shell (new, Rust):** GTK4 + libadwaita + WebKitGTK
  (`webkitgtk-6.0`).

The macOS app keeps building and running during every step; Phase 0 changes are
verified by the existing test suite and the prepush gate.

### 2. The boundary is a C ABI

The Swift core and the Rust shell meet over a C header (`chord_c.h`): an opaque
`chord_session_t*` handle, exported session/space/tab CRUD and navigation
commands, and a callback registry for core→shell events. Rationale:

- C is the one ABI both Swift (staticlib/dylib) and Rust (`bindgen` + `cc`
  crate) speak without a runtime bridge.
- It keeps the core language-agnostic: the same header is the contract a future
  Qt/KDE or CLI shell could implement.
- It prevents the Rust shell from leaking into the Swift side and vice-versa.

Threading: the core runs on its own actor thread; events cross a channel and are
dispatched onto the GTK main loop with `g_idle_add`.

### 3. WebKit identity is kept via WebKitGTK

The engine is the same WebKit, bound through WebKitGTK (`webkitgtk-6.0`, the
GTK4/libadwaita API — the stack GNOME Web ships). The macOS `WebEngine`
capabilities map onto WebKitGTK far better than feared:

| macOS capability | WebKitGTK | Verdict |
|---|---|---|
| Space isolation | one `WebKitWebContext`+`WebsiteDataManager` per Space | maps cleanly |
| `interactionState` | `WebKitViewSessionState` (serialize/restore) | maps |
| content blocking | `WebKitUserContentFilterStore` (compiled JSON) | maps |
| find | `WebKitFindController` + `count_matches` | better (real counts) |
| mute / zoom / UA / print / devtools / downloads | `set_is_muted`, `zoom_level`, user agent, `WebKitPrintOperation`, inspector, `WebKitDownload` | map |
| JS monitors (media, password form, adblock, geo, screen share) | `WebKitUserContentManager` script message handlers | port the JS, rehost |

### 4. Accepted drops on Linux

- **Extensions.** WKWebExtension has no WebKitGTK peer. `ChordExtensions` stays
  macOS-only.
- **Picture-in-Picture.** WebKitGTK exposes no `webkitSetPresentationMode`;
  even GNOME Web (the reference browser) ships without PiP.
- **Biometric keychain unlock.** Linux has no `LocalAuthentication` standard;
  the vault unlocks with the Secret Service master password.
- **Global shortcuts / swipe gestures** degrade on Wayland (portal
  GlobalShortcuts; no trackpad swipe events).
- **DRM** changes engine: FairPlay → Widevine via the GStreamer Flatpak
  extension. Streaming profile differs from macOS.

### 5. Phased rollout with a hard spike gate

- **Phase 0 — carve the seam (macOS-only, no behaviour change).** Neutral
  `WebEngine`; new `ChordPlatform` protocols (SecretStore, AppLog, Geo,
  Notifier, Shortcuts, Updater, Clipboard); de-import `ChordStore`; the C ABI
  module; a Linux CI job that `swift build`s and runs Core/Persistence/Store
  tests on Ubuntu.
- **Phase 1 — spike (decision gate).** Rust workspace (gtk4/libadwaita/
  webkit2gtk), `bindgen` over `chord_c.h`, link the Swift staticlib, threading
  bridge, a minimal window that loads a URL and round-trips title/URL/progress
  through the core. If the build chain or the bridge cannot be made solid here,
  the whole approach is reconsidered.
- **Phase 2 — engine parity.** Per-Space data isolation, navigation set,
  blocking, session restore, JS monitors, portal permissions, libsecret vault,
  Widevine.
- **Phase 3 — UX parity.** Command bar / Little Chord (`GtkPopover`), split
  panes, tab drag-reorder, sidebar DnD, Adwaita theming + HIG + AT-SPI.
- **Phase 4 — ship.** Flatpak on `org.gnome.Platform`, `.desktop` + AppStream,
  GitHub Actions (macOS + Linux + Flatpak), Flathub publishing, updater via the
  Flatpak update path.

## Rejected alternatives

- **CEF/Chromium backend.** Stable C API, real Widevine, Chrome extensions —
  but it is Chromium, not WebKit; the product identity changes. Rejected on
  "must stay WebKit."
- **Swift UI on Linux (SwiftGtk / SwiftOpenUI / QuillUI).** One language across
  both shells, but all three are experimental and unmaintained for this scale;
  betting the Linux product on the least-mature layer. Rejected.
- **Full rewrite (Rust/C++ + Qt).** Best long-term Linux citizen, discards the
  Swift core entirely. Rejected: the core (Core/Persistence/Store) is already
  ~40% of the code and fully portable.
- **No native app; sync + thin client.** Cheapest, but the goal is a real
  native WebKit browser on Linux. Rejected.

## Consequences

- Permanent two-engine, two-UI maintenance tax: macOS-only features touch only
  the Apple packages; Linux-only features touch only the Rust shell and the
  engine adapter.
- The C ABI becomes a stability contract; core changes must keep it stable or
  bump it deliberately.
- `Package.swift` splits into conditional targets (macOS excludes the Linux
  shell; Linux excludes the WebKit/AppKit packages).
- See bead epic for the tracked work breakdown.