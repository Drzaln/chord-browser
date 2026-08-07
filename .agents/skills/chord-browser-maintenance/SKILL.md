---
name: chord-browser-maintenance
description: Maintenance procedures, health checks, and upgrade workflows for the Chord Browser project. Covers prepush verification, WebKit SDK updates, content blocker refresh, schema migrations, dependency updates, performance soak testing, and known debt items.
---

# Chord Browser Maintenance Guide

Practical procedures for keeping the Chord Browser healthy. Use this skill when performing routine maintenance, upgrading dependencies, preparing a release, or diagnosing regressions.

---

## Quick Health Check

Run this whenever you pick up the project after time away:

```bash
# 1. Build all packages + run all tests + build the app (warnings = errors)
./scripts/prepush.sh

# 2. Verify test count hasn't regressed (expect 512+)
swift test --package-path Packages 2>&1 | tail -5

# 3. Check current schema version (should be v13)
sqlite3 ~/Library/Containers/com.rizal.browser/Data/Library/Application\ Support/Browser/browser.sqlite \
  "SELECT * FROM grdb_migrations ORDER BY identifier;"
```

If `prepush.sh` fails, fix before doing anything else. The project must compile at every commit.

---

## Routine Maintenance Tasks

### 1. Safari User-Agent String (quarterly)

The hard-coded Safari version in `WebKitEngine.safariUserAgentSuffix` goes stale. Check the current Safari version and update:

```bash
# Find the current value
grep -n "safariUserAgentSuffix\|applicationNameForUserAgent" \
  Packages/Sources/BrowserEngine/*.swift
```

Compare against the Safari version shipping with the current macOS. The UA should look like `Version/XX.Y Safari/605.1.15`. A stale-but-plausible version degrades far better than no token.

### 2. Content Blocker Lists (automatic, verify weekly)

The blocker auto-refreshes EasyList + EasyPrivacy weekly, **per list** — each
list has its own content-hash identifier, its own `lastRefresh` timestamp, and a
failed fetch defers only that list (it keeps its last good set and retries next
launch). Verify it's working:

```bash
# Check last refresh dates and the current per-list identifiers
defaults read com.rizal.browser 2>/dev/null | grep -i block
```

If the upstream URLs change or the ABP format evolves, update `ContentBlocker`'s fetch URLs in `BrowserEngine`. The in-house converter (`ContentBlockConverter` in `BrowserCore`) handles the ABP→JSON conversion — if new ABP syntax appears, add support there.

**Key numbers to remember:**
- ~137k rules from EasyList + EasyPrivacy combined
- Chunked at 50k per `WKContentRuleList` (3 chunks)
- 99.3% coverage (only ~945 lines skipped)
- Compile takes ~3.7s off-main, ~103 MB transient spike
- State keys: `contentBlocking.currentIdentifiers` (array), `contentBlocking.lastRefresh.<url>` (per list); legacy single `contentBlocking.currentIdentifier` is read once on upgrade

### 3. GRDB Dependency Update (as needed)

GRDB is the only third-party runtime dependency. Pinned to an exact version.

```bash
# Check current pin
cat Packages/Package.resolved | grep -A2 GRDB

# After updating, run full suite
swift test --package-path Packages
./scripts/prepush.sh
```

Never float the version. Review changelogs deliberately before bumping.

### 4. YouTube Ad Blocker Selectors (every ~2 weeks)

YouTube changes ad DOM constantly, so the injected script in
`Packages/Sources/BrowserEngine/YouTubeAdBlocker.swift` goes stale on its own
schedule — the selectors, not the browser, are what breaks. Follow the dedicated
playbook: **`.agents/skills/chord-browser-youtube-ads/SKILL.md`**. It covers the
upstream-signal check (uAssets / EasyList), the live-DOM probe, the visual smoke
pass, and what to update in the script. Open a `bd` issue for each run and close
it when the check (or update) is done.

---

## Xcode / macOS SDK Upgrade Procedure

When Apple ships a new Xcode or macOS:

### Step 1 — Verify WebKit API

Every `WK*` symbol used in `BrowserEngine` and `BrowserExtensions` must be checked against the new SDK headers:

```bash
SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
HEADERS="$SDK_PATH/System/Library/Frameworks/WebKit.framework/Headers"

# List all WK* types we reference
grep -rh "WK[A-Z]" Packages/Sources/BrowserEngine/ Packages/Sources/BrowserExtensions/ \
  | grep -oE 'WK[A-Za-z]+' | sort -u

# Then spot-check each against headers
grep "WKWebExtensionController" "$HEADERS"/*.h
```

Watch for:
- **Deprecated symbols** — adopt replacements before they're removed
- **Signature changes** — especially delegate methods
- **New capabilities** — gate behind `Capabilities.swift` if the deployment floor stays at 15.4

### Step 2 — Build and Test

```bash
./scripts/prepush.sh
```

### Step 3 — Verify Entitlement-Dependent Features

These **cannot** be tested by `swift test` (runs unsandboxed). Must verify against the real app:

| Feature | How to verify |
|---|---|
| **Downloads** | Download a file → appears in `~/Downloads` |
| **Print** | `Cmd+P` → print panel with live preview |
| **PDF viewing** | Navigate to a `.pdf` URL → renders inline |
| **Data store isolation** | Log into different accounts in two Spaces |
| **Content blocking** | Navigate to a known tracker URL → blocked |
| **Extensions** | Enable an extension → content script injects |
| **Extension signing warning** | Install an unsigned `.xpi` → orange warning icon on the row + install-time message + enable confirmation; a signed `.crx` is not warned |
| **Camera / microphone** | A `getUserMedia` site prompts once, then works. **Check the mic in a Release build** — Hardened Runtime uses a different entitlement key |
| **Notifications** | `bennish.net` → prompt once, banner appears, click focuses the tab |
| **Site permission memory** | Relaunch → no re-prompt; same site in another Space → prompts again |

### Step 4 — Performance Soak

```bash
# Seed the soak profile, run 30 minutes, then restore your real session
./scripts/soak.sh seed
./scripts/soak.sh run
./scripts/soak.sh restore
```

Budgets (Apple Silicon, 20 tabs, 3 Spaces, 5 live):

| Metric | Target | Hard ceiling |
|---|---|---|
| App RSS (excl. content) | < 150 MB | 250 MB |
| Total footprint | < 1.2 GB | 1.8 GB |
| Idle CPU (visible) | < 0.5% | 1% |
| Idle CPU (occluded) | ~0% | 0.2% |

---

## Adding a Schema Migration

Current: **v13**. Every migration is forward-only, named, never edited once shipped.

### Procedure

1. **Create the migration** in `BrowserPersistence` — a named function (`v14_description`)
2. **Add a fixture test** using the prior version's database, migrating `upTo:` the previous migration
   - **Two test files assert `Migrations.currentVersion` literally** — update both or prepush goes red
3. **Update row types and mappers** — never persist `Codable` app models directly
4. **Make decoding defensive** — a corrupt row costs one tab, never a launch
5. **Never delete user data** in a migration — orphan it and log
6. **Update CHECKPOINT.md** with the new schema version in the same commit

```bash
# Verify migration
swift test --package-path Packages --filter Migration
```

---

## Adding a New Feature

Before writing any code:

1. **Check scope** — §11 forbids adding features not in the current scope. Ask the user first
2. **Check the module boundary** — which package does this belong in?
   - Pure logic → `BrowserCore` (Foundation only)
   - WebKit interaction → `BrowserEngine` (the ONLY WebKit importer, with `BrowserExtensions`)
   - State management → `BrowserStore`
   - UI → `BrowserUI` (NO WebKit imports)
3. **Check for WebKit API** — verify symbols exist in SDK headers before using them
4. **Check performance** — flag anything that costs memory or main-thread time
5. **Write tests** — unit tests in the matching `Tests/` target, e2e if it touches the full stack

### Module Import Rules (compiler-enforced)

```
BrowserCore          ← Foundation ONLY
BrowserSecrets       ← Core + Security/LocalAuthentication (the vault's secret half)
BrowserPersistence   ← Core + GRDB
BrowserEngine        ← Core + WebKit
BrowserExtensions    ← Core + Engine + WebKit
BrowserStore         ← Core + Engine + Persistence + Extensions + Secrets (NO WebKit, NO AppKit)
BrowserUI            ← Core + Engine + Store + Extensions (NO WebKit)
```

If you need an upward call, define a protocol in the lower target and inject.

---

## Debugging Common Issues

### App won't launch / corrupt profile

```bash
# Nuclear reset — wipes ALL user data (cookies, Spaces, tabs, extensions)
scripts/reset-data.sh
# Add --yes to skip prompt, --build to also clear DerivedData
```

### Database corruption

**Never `cp` the database.** GRDB runs in WAL mode — a copy of the main file alone is stale.

```bash
# Correct way to snapshot
sqlite3 ~/Library/Containers/com.rizal.browser/Data/Library/Application\ Support/Browser/browser.sqlite ".backup /tmp/browser-backup.sqlite"

# If corrupted, attempt recovery
sqlite3 ~/Library/Containers/com.rizal.browser/Data/Library/Application\ Support/Browser/browser.sqlite ".recover" | sqlite3 /tmp/recovered.sqlite
```

### Content processes crashing

This is **normal** — `WKWebView` content processes die routinely. The app handles this via `webViewWebContentProcessDidTerminate`. If it's happening excessively, check:
- Memory pressure (too many live web views — cap is 12)
- A specific site triggering the crash (check Console for WebContent crash logs)

### "Chord cannot be opened because of a problem"

The bundle's signature is inconsistent — most often because something re-signed
the app without re-signing the nested `Chord.debug.dylib` a Debug build ships.
dyld reports *"different Team IDs"*, but the alert says nothing useful.

```bash
# The only place the real reason appears (AppLog's file won't have a dyld crash —
# it died before the app ran):
grep -oE '"reasons":\[[^]]*\]' "$(ls -t ~/Library/Logs/DiagnosticReports/Chord* | head -1)"
```

**Fix by clean-building, not by re-signing:** `xcodebuild -project
Browser.xcodeproj -scheme Browser -configuration Debug clean build`. Manual
`codesign --force` on the app and its dylibs does *not* recover it (measured
2026-07-31).

### The vault asks for the login-keychain password after a rebuild

Expected, and not a bug: an ad-hoc signature changes every build, and the
Keychain item's ACL trusts the identity that created it. Click **Always Allow**.
Signing with a stable self-signed certificate was tried and reverted — see
`docs/design/password-vault.md`.

### Camera works but the microphone does not

Almost always the entitlements, and it will look like a code bug because it is
**Release-only**: Hardened Runtime (Release) gates the mic behind
`com.apple.security.device.audio-input`, while App Sandbox uses
`com.apple.security.device.microphone`. Camera shares one key across both, which
is why it keeps working. Both mic keys must be in `BrowserApp/Browser.entitlements`.
Debug builds disable Hardened Runtime under ad-hoc signing, so they cannot
reproduce it.

### A site was allowed but still gets nothing

Two layers, both must be granted: Chord's per-site decision (Settings → Privacy &
Data → Site Permissions) and macOS's per-app grant (System Settings → Privacy &
Security). Neither layer can read the other's state, so the app cannot warn about
it. Check the OS layer first — it is the usual culprit after a fresh install.

### A site re-prompts for notifications on every visit

The shim seeds `Notification.permission` by *querying* the stored decision at
document start (`op: query`, no prompt). If a site re-asks every visit, the query
path is failing — check the with-reply handler `chordNotifyPermission` is
registered on that view and the origin matches what is stored (scheme + host, per
Space).

### An extension loads but does nothing (diagnose it directly)

First check the AppLog file (`Application Support/Browser/Logs/browser.log`) for
the `extensions` category — `WebKitExtensionHost` logs load/unload and errors
there. For the raw WebKit error surface, load the bundle into a real
`WKWebExtensionController` from a throwaway
script — `swift file.swift` outside the repo, WebKit is available unsandboxed —
and read `context.errors` a few seconds **after** `load` (they arrive late):

```swift
let ext = try await WKWebExtension(resourceBaseURL: zipURL)   // .crx: strip the Cr24 header first
let context = WKWebExtensionContext(for: ext)
for p in ext.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: p) }
try WKWebExtensionController(configuration: .init(identifier: UUID())).load(context)
// wait ~2s, then print each (error as NSError).domain / .code / .localizedDescription
```

How to read it:

- `WKWebExtensionContextErrorDomain` **code 6** = the background service worker
  threw while starting. The popup of a worker-dependent extension then hangs
  forever on a spinner.
- **Compare `ext.requestedPermissions` against the manifest.** WebKit silently
  drops permissions it does not implement (`offscreen`, `sidePanel`,
  `clipboardRead`, `webRequestAuthProvider`, `nativeMessaging`). A dropped
  permission means the API object is `undefined`, and an extension touching it at
  startup dies with exactly that code 6.
- Isolate with controls before blaming the platform: a minimal MV3 extension with
  a service worker should load **clean**; one that throws at top level reproduces
  code 6. That is how Bitwarden was pinned to `chrome.offscreen` (see CHECKPOINT).

### Extension not working

1. Check if it's MV3 (MV2 is rejected by the load guard)
2. Check if host permissions are granted (the "Access on all sites" toggle in the extensions panel)
3. Check rule count — `declarativeNetRequest` extensions with >50k rules in a single ruleset are rejected by WebKit
4. Content scripts only inject on page load — reload the tab after enabling

### Reading the log file

`os.Logger` is not retrievable via `log show`/`log stream` on this machine, but
`AppLog` mirrors every line to a rotating file. Read that:

```bash
LOG=~/Library/Containers/com.rizal.browser/Data/Library/Application\ Support/Browser/Logs/browser.log
tail -200 "$LOG"                                  # recent entries
grep -i "error\|fault" "$LOG"                     # errors across the session
tail -20 "${LOG}.1"                               # the rotated backup
```

Entries look like `2026-08-06T19:47:12Z [store] notice: …`. The file rotates at
5 MB (`browser.log.1` is the previous chunk).

### Visual verification

For on-screen state only (logs are in the file now):

```bash
screencapture -x -o /tmp/chord-check.png
# For a specific region:
screencapture -x -R<x>,<y>,<w>,<h> /tmp/chord-region.png
```

---

## Carried Debt Tracker

Items owed but not blocking. Check off as completed:

- [ ] **Full Instruments GUI trace** — SwiftUI body counts + Energy Log (§6.7). Leaks pass is clean
- [ ] **Sidebar scroll fps** measurement — screen recording available, never measured
- [ ] **Swipe gesture on real trackpad** — only logic tested, needs hands-on verification
- [ ] **Reduce Motion toggle** live check — code is auditable, never toggled in System Settings
- [ ] **Panel sizing** test coverage — bit twice (command bar + Little Arc), still uncovered in tests
- [x] **Soak re-run after the security pass (2026-08-07)** — 3 Spaces / 21 tabs / 42 panes, 30 min, no leak (app 69 MB steady, total 576–577 MB flat). §6.1 gate current — see SMOKE.md
- [ ] **Two distinct Google accounts** under two windows — needs a second credential set
- [ ] **Extensions with two windows open** — this profile has no extensions installed; install one first

---

## Git Workflow

```bash
# Stage everything except the Xcode project file
git add -A ':!Browser.xcodeproj/project.pbxproj'

# Commit/push ONLY when the user asks
# Always update CHECKPOINT.md in the same commit as the work it describes
```

Single `main` branch, linear history. No feature branches.

---

## Key File Locations

| What | Where |
|---|---|
| App entrypoint | `BrowserApp/BrowserApp.swift` |
| AppDelegate | `BrowserApp/AppDelegate.swift` |
| Entitlements | `BrowserApp/Browser.entitlements` |
| Package manifest | `Packages/Package.swift` |
| Migrations | `Packages/Sources/BrowserPersistence/Migrations/` |
| Content blocker | `Packages/Sources/BrowserEngine/ContentBlocker.swift` |
| ABP converter | `Packages/Sources/BrowserCore/ContentBlockConverter.swift` |
| Sweep policy | `Packages/Sources/BrowserCore/SweepPolicy.swift` |
| Site permissions (model) | `Packages/Sources/BrowserCore/SitePermission.swift` |
| Site permissions (storage) | `Packages/Sources/BrowserPersistence/SQLiteSitePermissionsRepository.swift` |
| Notification shim | `Packages/Sources/BrowserEngine/NotificationBridge.swift` + `BrowserApp/NotificationController.swift` |
| Logging sink | `Packages/Sources/BrowserLogging/AppLog.swift` |
| Log file | `~/Library/Containers/com.rizal.browser/Data/Library/Application Support/Browser/Logs/browser.log` |
| YouTube ad script | `Packages/Sources/BrowserEngine/YouTubeAdBlocker.swift` |
| Screen-share monitor | `Packages/Sources/BrowserEngine/ScreenShareMonitor.swift` |
| User-Agent presets | `Packages/Sources/BrowserCore/UserAgent.swift` |
| Fuzzy ranking | `Packages/Sources/BrowserCore/FuzzyRanking.swift` |
| ADRs | `docs/adr/` |
| Smoke tests | `SMOKE.md` |
| Soak harness | `scripts/soak.sh` |
| Seed blocklist | `Packages/Sources/BrowserEngine/Resources/seed-blocklist.txt` |
| Branding assets | `docs/branding/` |
| User guide | `docs/USER_GUIDE.md` |
| Sandboxed data | `~/Library/Containers/com.rizal.browser/Data/Library/Application Support/Browser/` |
