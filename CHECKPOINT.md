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
| **Completed** | M1 Browse, M2 Spaces, M3 Command bar + ephemeral tabs |
| **Next** | M4 — Session restore + downloads |
| **Tests** | 131 passing (121 unit + 10 end-to-end) |
| **Schema** | v3 (`v1_initial`, `v2_add_spaces`, `v3_history_and_archive`) |
| **Toolchain verified** | Swift 6.3.3, Xcode 26.6, macOS 26.5 host, target floor 15.4 |

**No milestone has passed its §6.1 performance gate yet** — see Carried debt.

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
  BrowserCore/           value types + pure logic (ranking, sweep policy). Foundation only.
  BrowserPersistence/    GRDB, migrations, row types, mappers
  BrowserEngine/         the ONLY package importing WebKit
  BrowserStore/          TabStore (+Spaces/+Sweep/+CommandBar), PaneRuntime, AppEnvironment
  BrowserUI/             SwiftUI + command bar panel. Imports Engine but never WebKit.
  BrowserTestSupport/    fakes, TabBuilder, TestHTTPServer
Packages/Tests/
  Browser*Tests/         unit tests per package
  BrowserE2ETests/       full stack: real engine + real SQLite + real HTTP
docs/adr/                why the non-obvious calls were made
```

Runtime data (the app is sandboxed):
`~/Library/Containers/com.rizal.browser/Data/Library/Application Support/Browser/`

## Invariants — do not break these

1. **No `WK*` type in `BrowserEngine`'s public interface.** UI sees web content
   only as `AnyWebSurface`. Resist adding a JS-eval method to observe pages —
   the e2e tests report through the page title instead, precisely to avoid it.
2. **`BrowserCore` imports Foundation and nothing else.** All the interesting
   logic (fuzzy ranking, sweep eligibility) lives there as pure functions, which
   is why it is testable without a UI, a clock, or WebKit.
3. **Restore is lazy.** N saved tabs must create 0 web views. Asserted in both
   unit and e2e tests.
4. **Volatile state (load progress) goes to `PaneRuntime`, never to `tabs`.**
5. **A web view belongs to the Space it was created in.** Resolve the Space from
   the *tab*, never the selection; evict before moving a tab. See ADR 006.
6. **Per-view `WKUserContentController`.** `WKWebViewConfiguration.copy()` shares
   it, and a duplicate script-handler name throws and kills the app on the
   second tab. See ADR 008.
7. **Never persist `Codable` app models.** Row types + mappers only.
8. **Decoding is defensive.** A corrupt row costs one tab, never a launch.
9. **Migrations are forward-only, named, never edited once shipped**, each with
   a fixture test built from the prior version (`Migrations.v1ForTesting`).
10. **Never invent WebKit API.** Verify against the SDK headers:
    `$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/WebKit.framework/Headers/`
    This is how the missing `isPlayingAudio` was caught before writing against it.

## Carried debt — clear before M5

- **No 30-minute soak has been run, for any milestone.** §8 gates every
  milestone on it and §6.7 wants Instruments passes at M1/M3/M7. Neither has
  happened. Footprint was ~139 MB with a few tabs (target < 150 MB); cold-launch,
  Space-switch, command-bar-open, and idle-CPU numbers are all unmeasured.
- **The command bar panel has never been seen running.** macOS blocks synthetic
  keystrokes without accessibility permission, so `Cmd+T` could not be driven
  from automation. The ranking and activation logic behind it are well covered;
  the `NSPanel` presentation is not. It is first in SMOKE.md's M3 section.
- M2's done-when *is* now proven end-to-end (a real page's cookie is invisible
  in another Space), but nobody has logged into two real Google accounts by hand.

## Deviations from the spec

Each has an ADR; the spec text was updated in the same commit.

- `WKProcessPool` unused — Apple deprecated it to a no-op (ADR 004)
- `BrowserStore` is a package the §3.5 list omitted (ADR 005)
- Audio playback detected by user script, not the SPI everyone else uses (ADR 008)
- `Cmd+T` opens the command bar per §4.4; plain new tab moved to `Cmd+N`

## Open decisions (BROWSER_SPEC §12)

- Extension contexts per-Space or global (M7)

Resolved: GRDB over Core Data (ADR 001); history is title/URL only (ADR 007);
archive keeps the last 100 with no time limit.

## Notes for M4

- `interactionState` is already captured on eviction and stored out-of-line in
  `paneInteractionState`, but **it is never written on ordinary deactivation** —
  M4 has to add that, debounced, or restore will only be as good as the last
  eviction.
- `TabRepository` already has `loadInteractionState`/`saveInteractionState`;
  nothing calls them from the store yet.
- Downloads need `WKDownloadDelegate`. Check the header before writing against
  it — do not assume the delegate method names.
- The archive deliberately drops `interactionState` (ADR 007 / 4.3); restoring
  an archived tab reloads. That is intended, not an oversight to fix in M4.
