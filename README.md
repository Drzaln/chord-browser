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
> shipped on `main` and verified live. 319 tests pass; `./scripts/prepush.sh` is
> green. See [CHECKPOINT.md](CHECKPOINT.md) for the detailed state and
> [BROWSER_SPEC.md](BROWSER_SPEC.md) for the full specification.

> 📖 **New here? Read the [User Guide](docs/USER_GUIDE.md)** — keyboard shortcuts,
> the command bar, Spaces, split view, extensions, and content blocking.

---

## Features

- **Browsing** — one window, a sidebar with a flat tab list, one `WKWebView` per
  tab, favicons/titles, and process-termination recovery.
- **Spaces** — isolated browsing contexts, each with its own
  `WKWebsiteDataStore`, so two Google accounts stay logged in simultaneously in
  two Spaces. Gradient theming per Space, `Cmd+1…9` to switch.
- **Command bar** — `Cmd+T` panel with fuzzy ranking over tabs and history.
- **Ephemeral tabs** — auto-sweep timer with archive.
- **Session restore** — `interactionState` persistence; a force-quit relaunch
  restores everything, including scroll and form state.
- **Downloads** — `WKDownload` handling with progress UI.
- **Split view + Little Arc** — multi-pane tabs and a floating quick-open panel.
- **Polish** — swipe-driven Space switching, cross-section drag-and-drop,
  find-in-page, print, and PDF viewing.
- **Frosted-glass chrome** — the sidebar and border frame are `.ultraThinMaterial`
  over the Space tint, blurring the desktop behind a non-opaque window; the web
  card stays opaque.
- **Extensions** — a `WKWebExtension` host with a `.crx`/`.xpi` unpack helper and
  popover surfacing. Install, enable per Space, and uninstall from **Settings**.
- **Settings** (`Cmd+,`) — clear browsing data (cache, cookies, site storage,
  history) across every Space, and manage extensions.
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
    BrowserExtensions/   WKWebExtension host + .crx unpack
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

This is a personal project. No license is currently granted for reuse,
redistribution, or modification. If you would like to use any part of it, please
open an issue or contact the author first. A permissive open-source license may
be added later.
