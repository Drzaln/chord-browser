# Chord Browser

<img src="docs/branding/chord-icon-1024.png" alt="Chord Browser icon" width="120" align="right" />

A native macOS browser built in Swift on top of `WKWebView`. It borrows **Arc's
interaction model** — Spaces, a fuzzy command bar, ephemeral tabs, a sidebar tab
list — while running on **Apple's own WebKit engine** rather than a bundled
Chromium. The goal is a personal, fast, memory-disciplined Arc replacement that
stays on the platform's rails.

The name plays on the geometry in the icon: a straight **chord** cutting across a
circle. Brand assets and colors are in [docs/branding/](docs/branding/BRANDING.md).

> **Status:** all spec milestones (M1–M7) plus native content blocking are
> shipped on `main` and verified live, along with a run of post-spec additions
> (multiple windows, folders, per-site permissions, notifications, YouTube ad
> skipping, a built-in password vault, and user-renamed tabs). 614 tests pass;
> schema is at v14; `./scripts/prepush.sh` is green.
> See [CHECKPOINT.md](CHECKPOINT.md) for the detailed state and
> [BROWSER_SPEC.md](BROWSER_SPEC.md) for the full specification.

> 📖 **New here? Read the [User Guide](docs/USER_GUIDE.md)** — keyboard shortcuts,
> the command bar, Spaces, split view, extensions, and content blocking.

---

## Features

- **Browsing** — a sidebar with a flat tab list, one `WKWebView` per tab,
  favicons/titles, and process-termination recovery.
- **Multiple windows** — `Cmd+N`. Sidebar, active Space, selection, and find are
  per window; tabs, Spaces, and folders are shared. Tabs drag between windows
  (with a confirm when the move crosses Spaces and therefore cookie stores), and
  each window's Space/tab is persisted and restored.
- **`window.open()` / `target="_blank"` popups** — new windows open as tabs, but
  as *real* popup web views: the page keeps its `window.open()` reference and
  `window.close()` actually closes the tab. That is what makes OAuth logins work
  — e.g. **"Continue with Google" on shopee.co.id** hands the login back and the
  popup tab closes itself instead of lingering
  ([ADR 018](docs/adr/018-window-open-popups-are-real-web-views.md)).
- **Spaces** — isolated browsing contexts, each with its own
  `WKWebsiteDataStore`, so two Google accounts stay logged in simultaneously in
  two Spaces. Gradient theming per Space, `Cmd+1…9` to switch.
- **Command bar** — `Cmd+T` panel with fuzzy ranking over tabs and history.
- **Ephemeral tabs** — auto-sweep timer with archive.
- **Favourites & Pinned tabs** — three tab tiers: a Favourites icon grid, a
  collapsible Pinned-tabs list (both sweep-exempt and homed at the URL they were
  pinned at — double-click/click to return, "Set Current Page as Pinned URL" to
  re-home), and ephemeral tabs. Closing a favourite or Pinned tab unloads it but
  keeps the sidebar entry and its favicon.
- **Session restore** — `interactionState` persistence; a force-quit relaunch
  restores everything, including scroll and form state.
- **Downloads** — `WKDownload` handling with progress UI.
- **Split view + Little Arc** — multi-pane tabs and a floating quick-open panel
  (shared with Peek; resizable and size-remembered).
- **Polish** — swipe-driven Space switching, cross-section drag-and-drop,
  find-in-page, print, and PDF viewing.
- **Frosted-glass chrome** — the sidebar and border frame are `.ultraThinMaterial`
  over the Space tint, blurring the desktop behind a non-opaque window; the web
  card stays opaque.
- **Extensions** — a `WKWebExtension` host with a `.crx`/`.xpi` unpack helper and
  popover surfacing. Install, enable per Space, and uninstall from **Settings**.
  Bundles are **signature-verified at install** (CRX2/CRX3); unsigned or
  unknown-signer ones still install but are flagged with a warning (ADR 017).
- **History** (`Cmd+Y`) — a searchable, **per-Space** window of visited pages
  grouped by day, with per-entry and multi-select delete, open-in-new-tab, and
  clear. Each Space keeps its own history, matching its isolated data store.
- **Folders** — group tabs in the sidebar into collapsible, renamable folders;
  foldered tabs are exempt from the auto-archive sweep.
- **Peek** — click a link inside a Favourite or Pinned tab and it opens in a
  floating preview instead of navigating the protected page away; promote with
  `⌘O` or dismiss with `Esc`.
- **Per-tab mute** — a speaker toggle on any tab making noise; sticks across
  reloads and silences every pane of a split.
- **Configurable search, new tab & archive time** — pick the search engine
  (Google, DuckDuckGo, Bing, Brave, or a custom `%s` template), what a new tab
  opens to (blank, the search engine's home, or a specific page), and how long
  before idle tabs are archived — all from **Settings → General**.
- **Password vault** — saves logins, offers them back, and fills on a click.
  Metadata lives in SQLite; the password itself lives in the **macOS Keychain**,
  never in the database. Filling requires an exact origin match and a deliberate
  click — never on page load. Manage or delete anything saved in **Settings →
  Passwords**, where revealing a password is gated behind Touch ID. Design,
  threat model, and phases in
  [docs/design/password-vault.md](docs/design/password-vault.md).
- **Site permissions** — camera, microphone, and web notifications are asked for
  **once per site, per Space**, then remembered, and are reviewable/revocable in
  Settings ([ADR 014](docs/adr/014-site-permissions-asked-once-per-space.md)).
- **Web notifications** — `window.Notification` is shimmed and delivered through
  Notification Center, with click-through back to the tab. Not Web Push: the page
  must be open ([ADR 015](docs/adr/015-web-notifications-by-shim.md)).
- **Screen-share awareness** — a "this page is sharing your screen" banner with a
  working Stop, plus Presentation mode (`Cmd+Ctrl+S`) for clean window sharing.
  Tab capture does not exist on WebKit
  ([ADR 012](docs/adr/012-screen-share-awareness-without-tab-capture.md)).
- **YouTube ad skipping** — a built-in script skips and fast-forwards YouTube and
  YouTube Music video ads and hides their static ad surfaces. Best-effort, and
  deliberately not an extension
  ([ADR 013](docs/adr/013-youtube-ad-blocking-by-user-script.md)). Kept current
  by a recurring selector-compatibility check (see
  [.agents/skills/chord-browser-youtube-ads](.agents/skills/chord-browser-youtube-ads/SKILL.md)).
- **User-Agent control** — Default / Chrome / Firefox / Safari-iPhone or a custom
  string from **Settings → General**, plus **per-domain override rules** (e.g.
  force `meet.google.com` back to Default), for the occasional site that sniffs.
- **Settings** (`Cmd+,`) — General preferences, clear browsing data (cache,
  cookies, site storage, history) across every Space, per-site permission
  management, and extensions.
- **Native content blocking** — see below.

### Content blocking

Blocking is **on by default** and native — it compiles EasyList + EasyPrivacy
into `WKContentRuleList`s, caches the compiled lists on disk, and refreshes them
weekly. Because the compiled list is a shared, immutable WebKit object, attaching
it to every view costs almost nothing and adds no measurable idle CPU.

Both **network** filtering (drop tracker/ad requests) and **cosmetic** filtering
(hide ad elements via `css-display-none`) are supported. Standard CSS `:has()`
container-hiding rules are honoured — verified end-to-end against WebKit — which
recovers hundreds of EasyList element-hiding rules that hide the wrapper _around_
an ad.

**What it cannot do (by design):** `WKContentRuleList` cannot run scriptlets, so
first-party-served video ads — most notably **YouTube's** — are _not_ blockable
through this path. Defeating those requires runtime JavaScript injection, which is
a different engine entirely (this is how Brave and uBlock Origin do it) and is
out of scope for the native approach. Proprietary procedural cosmetic filters
(`:upward`, `:xpath`, `:-abp-`, …) are likewise dropped rather than mis-applied.

**Why a Chrome ad blocker (AdBlock, uBlock Origin) can't stand in for this:**
Chromium browsers (Arc, Brave, Chrome) and Orion (WebKit, but with a custom
extension runtime Kagi built) can run those extensions with full request-blocking
and scriptlet injection. This browser uses WebKit + Apple's `WKWebExtension`,
which caps blocking rules (~50k, below AdBlock's ~63k) and offers no
request-blocking or scriptlet injection — so those extensions can't block here.
The built-in blocker above is the intended path. Full analysis and future options
are in [CHECKPOINT.md](CHECKPOINT.md) ("Ad-blocking & YouTube") and the
[User Guide](docs/USER_GUIDE.md#content-blocking).

### Known platform limits

These are properties of WebKit-without-Safari-entitlements, not bugs, and each is
recorded where it was diagnosed so it is not re-litigated:

- **No hardware AV1.** macOS gives the AV1 hardware-decode path to Safari, so
  `mediaCapabilities` reports AV1 as not power-efficient here and sites serve VP9
  (YouTube) or a softer ladder (Meta Reels). Everything else decodes in hardware.
  The `Cmd+Ctrl+P` debug overlay reports per-codec `hw`/`sw`/`no` so this can be
  re-checked on a future macOS.
- **No Web Push.** Notifications work while the page is open; background delivery
  needs Safari-gated APNs (ADR 015).
- **No tab capture.** Screen sharing offers screen and window, never "this tab"
  (ADR 012).
- **No first-party video-ad blocking through content rules** — see above; the
  YouTube case is handled by its own script (ADR 013).
- **No passkeys.** A plain `WKWebView` reports no platform authenticator, and the
  native path needs an Associated Domains entitlement per relying-party domain —
  impossible for sites you do not own. Measured, not assumed.
- **No password-manager extensions.** Bitwarden's MV3 build dies at startup
  because Apple's runtime does not implement `chrome.offscreen`; most MV3
  managers use it. The built-in vault above exists because of this.

---

## Requirements

- **macOS 15.4** or later (the deployment target).
- **Xcode 16+** with the macOS SDK.
- A Swift toolchain (bundled with Xcode).

No third-party runtime beyond the Swift packages resolved automatically
([GRDB](https://github.com/groue/GRDB.swift) for persistence).

---

## Building and running

### In Xcode

```bash
open Browser.xcodeproj
```

Select the **Browser** scheme and run (`Cmd+R`).

### From the command line

Build and test the packages, then build the app:

```bash
./scripts/prepush.sh
```

This is the local CI gate ([BROWSER_SPEC §7.6](BROWSER_SPEC.md)): it builds every
package with **warnings-as-errors**, runs the full test suite, and builds the app.
Run it before every push.

To build or test just the Swift packages:

```bash
swift build --package-path Packages -Xswiftc -warnings-as-errors
swift test  --package-path Packages
```

> **Note:** `swift test` runs **unsandboxed**, so anything entitlement-dependent
> (data-store isolation, downloads to protected locations) must be verified
> against the real app, not the package tests.

### Resetting to a clean profile

The app is sandboxed, so all user state (cookies, Spaces, tabs, history,
extensions, caches, preferences) lives in one container. To wipe it and start
fresh — e.g. before using a Release build daily:

```bash
scripts/reset-data.sh
```

It quits the app and prompts before deleting. Flags: `--yes` skips the prompt,
`--build` also clears `DerivedData`/`Packages/.build`. Irreversible.

It clears the profile *inside* the container's `Data/` folder — it deliberately
leaves the container shell and its `.com.apple.containermanagerd.metadata.plist`,
which macOS manages and won't let you delete without Full Disk Access. That's
harmless: the app recreates a fresh `Data/Library` on next launch.

---

## Project layout

```
BrowserApp/            The macOS app target (AppDelegate, entitlements, Info.plist)
Browser.xcodeproj/     Xcode project wrapping the app + Swift packages
Packages/              All logic, as a Swift package (BrowserPackages)
  Sources/
    BrowserCore/         Value types, no WebKit — models, converters, ranking
    BrowserPersistence/  GRDB-backed storage (history, tabs, spaces)
    BrowserEngine/       The WebKit-importing layer (WKWebView, content blocking)
    BrowserExtensions/   WKWebExtension host + .crx unpack + signature stamping
    BrowserCrypto/       Security/CryptoKit — extension signature verification
    BrowserStore/        App state store
    BrowserUI/           SwiftUI views
  Tests/                 One test suite per source module
scripts/               prepush.sh (local CI), soak.sh (memory soak harness)
docs/adr/              Architecture Decision Records
BROWSER_SPEC.md        The full specification (read this first)
CHECKPOINT.md          Living status log, updated with the work it describes
SMOKE.md               Manual smoke-test checklists and soak measurements
```

**Architectural rule:** WebKit is imported only inside `BrowserEngine` (and the
extension/UI layers that need it). Compiled `WKContentRuleList`s and `WKWebView`s
never leak above the engine boundary — everything above it works in plain value
types. See [BROWSER_SPEC §3](BROWSER_SPEC.md) and [docs/adr/](docs/adr).

---

## Development notes

This project follows a strict set of working agreements
([BROWSER_SPEC §11](BROWSER_SPEC.md)). The load-bearing ones:

- **Never invent WebKit API.** Check the SDK headers before assuming a symbol or
  signature exists; report when something does not exist rather than guessing.
- **Verify UI work by driving the real app**, not by reasoning about it.
- **Before trusting a regression test, watch it fail against the bug** it claims
  to cover, then put the fix back.
- **No performance debt carried forward** — every milestone is gated on
  [§6](BROWSER_SPEC.md)'s memory and CPU budgets via a 30-minute soak.
- **Stay in scope** — no features outside the current milestone without asking.

---

## License

Copyright © 2026 Doddy Rizal Novianto.

**Source-available, all rights reserved.** This repository is public so the code
can be read and studied, but no license is currently granted: you may not reuse,
redistribute, or modify any part of it. If you would like to use any part of it,
please open an issue or contact the author first. A permissive open-source
license may be added later.
