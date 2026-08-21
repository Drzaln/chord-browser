# Chord Browser — Workspace Rules

## Identity

This is **Chord Browser**, a native macOS browser in Swift on `WKWebView`. It replicates Arc's interaction model on WebKit. The codebase name is `Chord` internally; the user-facing brand is "Chord".

## Critical Working Agreements (from BROWSER_SPEC §11)

1. **Never invent WebKit API.** Verify every `WK*` symbol, initialiser, or delegate method against the SDK headers at `$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/WebKit.framework/Headers/` before using it. If unsure whether something exists, say so and ask — do not guess.
2. **Keep the project compiling at every commit.**
3. **No TODO stubs that silently return empty values.** Use `fatalError("unimplemented: <what>")` so it is loud.
4. **Do not add features, settings, or abstractions not in the current scope.** Ask first.
5. **When a spec item is infeasible, say so** and propose an alternative — do not silently substitute.
6. **Prefer boring, explicit code.** This is a long-lived personal tool, not a demo.
7. **Performance is a correctness property.** Flag any design choice that costs memory or main-thread time before writing it.

## Architecture Invariants (never break these)

1. **No `WK*` type in `ChordEngine`'s public interface.** UI sees web content only as `AnyWebSurface`.
2. **`ChordCore` imports Foundation and nothing else.** All pure logic (fuzzy ranking, sweep eligibility) lives here.
3. **`ChordUI` must not import WebKit.** It receives opaque views from Engine.
4. **Restore is lazy.** N saved tabs create 0 web views at launch.
5. **A web view belongs to the Space it was created in** — resolve Space from the _tab_, never the selection.
6. **Per-view `WKUserContentController`.** `WKWebViewConfiguration.copy()` shares it — duplicate script-handler names crash.
7. **Keyboard shortcuts live in `ChordCommands` only** — view-level `.keyboardShortcut` silently beats menu items. A command that acts on a *window* reads `@FocusedValue(\.windowState)`, never `NSApp.mainWindow`.
7b. **Window state goes in `WindowState`, world state in `TabStore`.** Sidebar, sheets, collapse, find, *and selection* (`activeSpaceID`, `selectedTabID`) are per-window; tabs, Spaces, folders, and persistence are shared. Pass the window explicitly — `TabStore`'s no-argument forms are migration scaffolding that silently mean "the primary window".
7c. **A mutation that removes tabs or Spaces must call `reconcileWindows(excluding:)`.** The acting window picks its own next selection; the others only get re-pointed off what vanished. Anything that asks "is this tab in use?" must ask *every* window (`isSelectedByAnyWindow`) — that is what stops the sweep archiving a page open in another window.
8. **Never persist `Codable` app models.** Row types + mappers only.
9. **Decoding is defensive.** A corrupt row costs one tab, never a launch.
10. **Migrations are forward-only, named, never edited once shipped.** A migration that re-scopes data adopts existing rows (v6, v11); it never drops them.
11. **A capability a page asks for is decided per (Space, origin), asked once, remembered, and revocable in Settings** — camera, microphone, notifications (ADR 014). Never re-introduce a blanket grant.
12. **A password secret never leaves `ChordSecrets`.** Metadata (origin, username, timestamps) goes in SQLite; the secret goes in the Keychain, joined by `Credential.id`. Fill matching is **exact origin equality** — never parent-domain, never scheme-relaxed. Filling uses the **prototype** value setter (a direct `el.value =` is swallowed by React's value tracker), and the origin is re-checked inside the engine at the moment of writing.
13. **Device-gated features need a real app and real signatures.** Camera/mic require `com.apple.security.device.camera`/`.microphone`/`.audio-input` in `ChordApp/Chord.entitlements` — WebKit derives its WebContent child sandbox from the host entitlements, so they are required even though the app is unsandboxed. Both Debug and Release carry all three keys and Hardened Runtime, so Debug *can* reproduce device bugs; `swift test` (unsandboxed) still cannot.

## Build & Test

- **Local CI:** `./scripts/prepush.sh` — builds all packages with warnings-as-errors, runs full test suite, builds the app. Run before every push.
- **Package-only:** `swift build --package-path Packages -Xswiftc -warnings-as-errors` / `swift test --package-path Packages`
- **`swift test` runs UNSANDBOXED** — anything entitlement-dependent (data-store isolation, downloads, print) must be verified against the real app.
- **Reset profile:** `scripts/reset-data.sh`

## Module Dependencies (downward only)

```
ChordCore          ← Foundation only, no WebKit, no SwiftUI
ChordSecrets       ← Core + Security/LocalAuthentication (vault half — ADR 016)
ChordCrypto        ← Core + Security/CryptoKit (extension signature verification — ADR 017)
ChordPersistence   ← Core + GRDB
ChordEngine        ← Core + WebKit (the ONLY WebKit importer, with ChordExtensions)
ChordExtensions    ← Core + Crypto + Engine + WebKit
ChordStore         ← Core + Engine + Persistence + Extensions
ChordUI            ← Core + Engine + Store + Extensions (NO WebKit imports)
ChordTestSupport   ← fakes, fixtures, builders (test-only)
```

## Schema

Current version: **v14**. Migrations: `v1_initial`, `v2_add_spaces`, `v3_history_and_archive`, `v4_extension_enablement`, `v5_granted_permissions`, `v6_history_per_space`, `v7_folders`, `v8_pinned_home_url`, `v9_window_layout`, `v10_site_permissions`, `v11_site_permissions_per_space`, `v12_credentials`, `v13_credential_never_save`, `v14_tab_custom_title`. Each migration has a fixture test, and **two test files assert `Migrations.currentVersion` literally** — update both. Test baseline: **633** (`swift test`).

## Git

- Single `main` branch, linear history.
- Stage with `git add -A ':!Chord.xcodeproj/project.pbxproj'` — exclude the Xcode project file, *unless* the change is a deliberate build-config edit (e.g. the 2026-08-20 signing fix that removed the ad-hoc `CODE_SIGN_IDENTITY[sdk=macosx*] = "-"` override).
- Commit/push ONLY when the user asks.
- Update `CHECKPOINT.md` in the same commit as the work it describes.

## Logging

- Log through `AppLog` (`ChordLogging` package): one subsystem and a category per package, no `print`. Every line goes to `os.Logger` **and**, once installed (the app does this at launch), to a rotating file at `Application Support/Chord/Logs/chord.log`.
- `os.Logger` is NOT retrievable via `log show`/`log stream` on this machine — read the file instead. Only use `screencapture -x -o out.png` for visual verification, not for reading logs.

## Toolchain

- Swift 6, strict concurrency. Xcode 16+. macOS 15.4 deployment target (hard floor).
- GRDB for persistence. No Core Data.
- No third-party runtime dependencies beyond GRDB.
