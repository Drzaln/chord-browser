# 021 — GitHub-release self-updater

**Status:** accepted (post-M7, shipped 2026-08-22)

## Context

Chord ships directly/notarized (unsandboxed), not via the Mac App Store, so
updates have been a manual chore: pull the latest `Chord.zip` from the GitHub
releases page, replace the app, relaunch. The user asked for the browser to do
that itself — check GitHub for a newer release, and on confirmation download the
zip, extract it, and move the `.app` into `/Applications`.

The project has two load-bearing constraints that shaped the design:

- **Layering (§3.1) and the one-OS-framework-per-target rule (ADR 011).** WebKit
  stays below the engine boundary; Security/CryptoKit and
  LocalAuthentication each got their own package. An updater that imports AppKit
  would quietly break the pattern — especially the terminate/relaunch half.
- **Never do work the user did not ask for.** This browser already had `FeatureFlags`
  deleted for being "always on". An updater that silently downloads and replaces
  the running app is worse than a feature flag — it is a system-mutation risk.

## Decision

**Build a Foundation-only `ChordUpdater` package; keep every step manual; keep
relaunch in the UI layer.**

- **Check.** `GitHubReleaseChecking` hits `GET /repos/Drzaln/chord-browser/
  releases/latest` (with a `User-Agent`, which GitHub requires). 404 → "no
  releases yet". Prereleases are never offered.
- **Compare.** A small SemVer `Version` type (`major.minor.patch`, optional
  `-prerelease`, `v` prefix tolerated) with proper precedence: a prerelease
  sorts below the corresponding release, so `1.3.0-beta` is not an update over
  `1.2.0` but `1.3.0` is. The running version comes from the bundle's
  `CFBundleShortVersionString` at runtime — whatever is actually installed is
  what gets compared.
- **Install.** `AppInstaller` downloads the zip with `URLSession` (progress
  delegate), extracts it with **`ditto -x -k`** rather than a ZIP library —
  ditto preserves the bundle's symlinks, permissions, and metadata that the
  ZIP-archive APIs get wrong — finds the first `.app`, removes the existing copy
  at the destination, and moves the new one in. Replacing a running `.app` is
  safe on macOS; the process keeps running from the already-mapped executable.
  The quarantine attribute is stripped (`xattr -dr com.apple.quarantine`)
  because the user explicitly initiated this update and the app is notarized.
- **Relaunch.** Lives in `ChordUI` (the one place that may touch AppKit): a
  detached `/bin/bash` helper loops on `pgrep -x Chord`, and once this process
  has exited — letting `applicationShouldTerminate` flush session state — it
  `open -n`s the installed app through LaunchServices. Then
  `NSApp.terminate(nil)`.

An `@MainActor @Observable UpdateController` carries the state machine
(idle → checking → updateAvailable → downloading → extracting → installing →
readyToRestart → failed) and drives the Settings → Updates UI.

## Why not Sparkle

Sparkle is the obvious third-party answer, but this project's dependency
discipline (one SPM dep, GRDB) and its "never invent WebKit API / verify by
driving the real app" ethos argue for keeping the updater small, in-repo, and
reading the exact release mechanism the project already publishes with
(`Chord.zip` on GitHub releases). The trade-off — no delta updates, no
signed-update-channel infrastructure — is acceptable for a personal browser.

## Consequences

- Users update from **Settings → Updates** with two explicit clicks
  (Download & Install, then Restart Now). Nothing downloads on its own.
- Publishing a release is **automated** (2026-08-22): `.github/workflows/
  release.yml` runs on any `v*` tag push, builds the Release configuration on a
  macOS runner, packages `Chord.zip` (same `Chord/Chord.app` layout), and
  creates the GitHub Release via `softprops/action-gh-release` — so the updater
  finds it the moment the tag lands. It verifies the tag matches the app's
  `CFBundleShortVersionString` (the exact failure that would make the updater
  report "up to date" forever) and fails otherwise. It signs with the developer
  certificate when `MACOS_CERTIFICATE_BASE64`/`MACOS_CERTIFICATE_PASSWORD`
  secrets are set (keeping the signature stable for TCC/Keychain), else ad-hoc.
- Release cadence now matters to the running app: a published release must have
  a SemVer tag **and** a `Chord.zip` asset, or the section shows "up to date"
  (no asset) or an error (bad tag).
- Stripping quarantine on an explicitly-requested update is a deliberate trust
  decision; it does not weaken the notarized signature path for normal
  distribution.
- A newer *local* build than the latest release reports "up to date" — the
  comparison is directional (latest > installed), so dev builds never nag.