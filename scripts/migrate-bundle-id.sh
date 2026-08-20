#!/bin/bash
# One-time migration: move on-disk data from the old bundle id
# (com.rizal.browser) to the new one (com.rizal.chord) after the internal
# Browser -> Chord rename.
#
# The app is sandboxed, so the new bundle id cannot read the old container from
# inside the app. This script runs OUTSIDE the sandbox and must be run once,
# with the app quit. Run it before the first launch of the renamed app.
#
# What it migrates:
#   - UserDefaults plist            com.rizal.browser -> com.rizal.chord
#   - Sandbox container Data/       ~/Library/Containers/com.rizal.browser
#       . Application Support/Browser -> Chord (browser.sqlite/log -> chord.*)
#       . Downloads, Favicons, Extensions, cookies — moved wholesale with Data/
#   - Unsandboxed dev path          ~/Library/Application Support/Browser -> Chord
#       (used by `swift test` and extension unpack during development)
#
# The vault PASSWORD (Keychain) is migrated in-app at launch by
# `KeychainSecretStore.migrateVault` — Keychain items are reachable by service
# string, unlike the container.
#
# Idempotent: each step only runs when the destination does not already exist,
# so re-running is a safe no-op.
#
#     scripts/migrate-bundle-id.sh
#     scripts/migrate-bundle-id.sh --force   # replace an existing fresh profile
set -euo pipefail

OLD_BUNDLE="com.rizal.browser"
NEW_BUNDLE="com.rizal.chord"
OLD_APP_NAME="Browser"
NEW_APP_NAME="Chord"
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# Rename the pre-rename data files inside an Application Support folder.
rename_legacy_files() {
    local dir="$1"
    for f in browser.sqlite browser.sqlite-wal browser.sqlite-shm \
             browser.log browser.log.1 browser.log.2; do
        if [ -f "$dir/$f" ]; then
            mv -f "$dir/$f" "$dir/${f/browser/chord}"
        fi
    done
}

# 0. Quit any running instance (old or new binary), or open files keep the
#    container half-alive and the move fails.
osascript -e "tell application \"$NEW_APP_NAME\" to quit" >/dev/null 2>&1 || true
osascript -e "tell application \"$OLD_APP_NAME\" to quit" >/dev/null 2>&1 || true
pkill -x "$NEW_APP_NAME" >/dev/null 2>&1 || true
pkill -x "$OLD_APP_NAME" >/dev/null 2>&1 || true
sleep 1

# 1. UserDefaults. Old wins — the new app may already have written a fresh,
#    near-empty plist after its first launch.
OLD_PREFS="$HOME/Library/Preferences/$OLD_BUNDLE.plist"
NEW_PREFS="$HOME/Library/Preferences/$NEW_BUNDLE.plist"
if [ -f "$OLD_PREFS" ]; then
    cp -f "$OLD_PREFS" "$NEW_PREFS"
    echo "migrated preferences: $OLD_BUNDLE -> $NEW_BUNDLE"
else
    echo "no legacy preferences found ($OLD_PREFS)"
fi

# 2. Sandbox container.
OLD_CONT="$HOME/Library/Containers/$OLD_BUNDLE"
NEW_CONT="$HOME/Library/Containers/$NEW_BUNDLE"
if [ -d "$OLD_CONT/Data" ]; then
    # If the renamed app has already been launched once it created its own fresh
    # (empty) Data. Only replace that when the new profile is empty; if it has
    # real data we refuse and print a hint rather than clobber it.
    if [ -e "$NEW_CONT/Data" ] \
        && [ -n "$(ls -A "$NEW_CONT/Data/Library/Application Support/Chord" 2>/dev/null)" ]; then
        if [ "$FORCE" -eq 1 ]; then
            rm -rf "$NEW_CONT/Data"
            mkdir -p "$NEW_CONT"
            mv "$OLD_CONT/Data" "$NEW_CONT/Data"
            echo "migrated container (--force replaced a fresh profile)"
        else
            echo "!! new profile already has data; not overwriting" >&2
            echo "!! re-run with --force to replace it with the legacy profile" >&2
        fi
    else
        rm -rf "$NEW_CONT/Data"
        mkdir -p "$NEW_CONT"
        mv "$OLD_CONT/Data" "$NEW_CONT/Data"
        echo "migrated container: $OLD_CONT/Data -> $NEW_CONT/Data"
    fi

    APP_SUPPORT="$NEW_CONT/Data/Library/Application Support"
    if [ -d "$APP_SUPPORT/Browser" ] && [ ! -d "$APP_SUPPORT/Chord" ]; then
        mv "$APP_SUPPORT/Browser" "$APP_SUPPORT/Chord"
        echo "renamed Application Support folder: Browser -> Chord"
    fi
    [ -d "$APP_SUPPORT/Chord" ] && rename_legacy_files "$APP_SUPPORT/Chord"
    [ -d "$APP_SUPPORT/Chord/Logs" ] && rename_legacy_files "$APP_SUPPORT/Chord/Logs"
else
    echo "no legacy container found ($OLD_CONT)"
fi

# 3. Unsandboxed dev path (swift test / extension unpack).
OLD_DEV="$HOME/Library/Application Support/Browser"
NEW_DEV="$HOME/Library/Application Support/Chord"
if [ -d "$OLD_DEV" ] && [ ! -d "$NEW_DEV" ]; then
    mv "$OLD_DEV" "$NEW_DEV"
    rename_legacy_files "$NEW_DEV"
    [ -d "$NEW_DEV/Logs" ] && rename_legacy_files "$NEW_DEV/Logs"
    echo "migrated dev Application Support: Browser -> Chord"
else
    [ -d "$OLD_DEV" ] && echo "dev Application Support already migrated" \
        || echo "no legacy dev Application Support found ($OLD_DEV)"
fi

echo "Done."
