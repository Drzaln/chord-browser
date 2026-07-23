# Checkpoint

Living handoff document. **Update it in the same commit as the work it
describes** — a stale checkpoint is worse than none, because the next agent will
believe it.

Read [BROWSER_SPEC.md](BROWSER_SPEC.md) first. It is the contract; this file is
only the current position within it.

---

## Status

| | |
|---|---|
| **Completed** | M1 — Browse (`m1-browse`), M2 — Spaces (`m2-spaces`) |
| **Next** | M3 — Command bar + ephemeral tabs |
| **Tests** | 93 passing |
| **Schema** | v2 (`v1_initial`, `v2_add_spaces`) |
| **Toolchain verified** | Swift 6.3.3, Xcode 26.6, macOS 26.5 host, target floor 15.4 |

**Both milestones are code-complete but neither has passed its performance
gate** — see "Carried debt" below. Do not treat them as fully signed off.

## Build and verify

```bash
./scripts/prepush.sh
```

Builds all packages, runs all tests, builds the app. Warnings are errors.
Manual checks live in [SMOKE.md](SMOKE.md).

## Where things are

```
BrowserApp/              @main, AppDelegate, debug overlay (Cmd+Ctrl+P, DEBUG only)
Packages/Sources/
  BrowserCore/           value types + protocols. Foundation only.
  BrowserPersistence/    GRDB, migrations, row types, mappers
  BrowserEngine/         the ONLY package importing WebKit
  BrowserStore/          TabStore, PaneRuntime, AppEnvironment
  BrowserUI/             SwiftUI. Imports Engine but never WebKit.
  BrowserTestSupport/    fakes + TabBuilder
docs/adr/                why the non-obvious calls were made
```

Runtime data lives in the app container (it is sandboxed):
`~/Library/Containers/com.rizal.browser/Data/Library/Application Support/Browser/`

## Invariants — do not break these

1. **No `WK*` type in `BrowserEngine`'s public interface.** UI sees web content
   only as `AnyWebSurface`. This is what keeps a WebKit change to one package.
2. **`BrowserCore` imports Foundation and nothing else.**
3. **Restore is lazy.** N saved tabs must create 0 web views. Tests assert this;
   if one fails, something started instantiating eagerly.
4. **Volatile state (load progress) goes to `PaneRuntime`, never to `tabs`.**
   Writing it to the model redraws the sidebar 60×/sec.
5. **A web view belongs to the Space it was created in.** Resolve the Space from
   the *tab*, never from the current selection, and evict before moving a tab
   between Spaces — otherwise cookies leak across Spaces. See ADR 006.
6. **Never persist `Codable` app models.** Row types + mappers only.
7. **Decoding is defensive.** A corrupt row costs one tab, never a launch. An
   orphaned tab is re-homed, never dropped.
8. **Migrations are forward-only, named, never edited once shipped**, each with
   a fixture test built from the prior version
   (`Migrations.v1ForTesting` shows the pattern).
9. **Never invent WebKit API.** Verify against the SDK headers:
   `$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/WebKit.framework/Headers/`

## Carried debt — clear before M4

- **No 30-minute soak has been run, for M1 or M2.** §8 gates every milestone on
  it. Footprint was ~139 MB with a few tabs (target < 150 MB); cold-launch,
  Space-switch, and idle-CPU numbers are all unmeasured.
- **The M2 done-when is unverified by a human**: two Google accounts logged in
  simultaneously across two Spaces. Cookie isolation *is* proven by
  `DataStoreIsolationTests` against real `WKWebsiteDataStore`s, but nobody has
  driven the real UI through it.
- §6.7 asks for Instruments profiling at the end of M1, M3, and M7. M1's was
  not done.

## Deviations from the spec so far

Each has an ADR; the spec text was updated in the same commit.

- `WKProcessPool` is not used — Apple deprecated it to a no-op (ADR 004)
- `BrowserStore` is a package the §3.5 list omitted (ADR 005)
- `BrowserUI` imports `BrowserEngine`; the rule that holds is *no WebKit* in UI

## Open decisions (BROWSER_SPEC §12)

- History full-text searchable or title/URL only (**M3 — decide next**)
- Archive retention for swept ephemeral tabs (**M3 — decide next**)
- Extension contexts per-Space or global (M7)

Resolved: GRDB over Core Data (ADR 001).

## Notes for M3

- `Clock` already exists in `BrowserCore` and is injected — the ephemeral sweep
  must use it, not `Date()`, or the sweep tests become time-dependent.
- `URLInput.resolve` in `BrowserCore` already handles URL-vs-search and is
  reusable by the command bar unchanged.
- The sweep must exempt pinned tabs and audio-playing tabs (4.3). Audio state is
  not yet surfaced through `PaneSnapshot` — it will need adding there, and
  `WKWebView` exposes it via KVO on a media-playback property; check the header
  before assuming a name.
- Sweeps must stop while the window is occluded (6.3); `setOccluded` already
  threads through `TabStore`.
