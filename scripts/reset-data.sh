#!/bin/bash
# Wipe all of Chord's user data for a clean-slate profile (BROWSER_SPEC 3.3).
#
# The app is sandboxed, so every bit of user state — cookies/logins, Spaces,
# tabs, history, installed extensions, granted permissions, compiled blocklists,
# caches, and UserDefaults — lives under one container. Deleting it resets the
# app to a fresh profile on next launch. Debug and Release share the container
# (same bundle id), so this resets both.
#
# This is IRREVERSIBLE. It requires an explicit confirmation so it can never wipe
# by accident:
#     scripts/reset-data.sh            # prompts y/N
#     scripts/reset-data.sh --yes      # no prompt (for scripting)
#     scripts/reset-data.sh --build    # also clears build artifacts
set -euo pipefail

BUNDLE_ID="com.rizal.chord"   # keep in sync with PRODUCT_BUNDLE_IDENTIFIER
APP_NAME="Chord"                 # CFBundleName, used to quit the running app
CONTAINER="$HOME/Library/Containers/$BUNDLE_ID"

ASSUME_YES=0
CLEAN_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=1 ;;
        --build)  CLEAN_BUILD=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

echo "This will PERMANENTLY delete all of $APP_NAME's data under:"
echo "  $CONTAINER/Data"
if [ ! -d "$CONTAINER/Data" ] || [ -z "$(ls -A "$CONTAINER/Data" 2>/dev/null)" ]; then
    echo "  (already empty — nothing to delete)"
fi
[ "$CLEAN_BUILD" -eq 1 ] && echo "  + build artifacts (DerivedData/Chord-*, Packages/.build)"

if [ "$ASSUME_YES" -ne 1 ]; then
    printf "Type 'y' to continue: "
    read -r reply
    [ "$reply" = "y" ] || { echo "Aborted."; exit 1; }
fi

# Quit the app first, or open files keep the container half-alive.
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -x Chord     >/dev/null 2>&1 || true   # in case it launched as the target name
sleep 1

# Delete everything *inside* Data/ (the profile: Library/, symlinks, dotfiles).
# We do NOT remove the container root or its
# .com.apple.containermanagerd.metadata.plist — those are managed by macOS's
# containermanagerd and refuse deletion without Full Disk Access. Leaving the
# empty shell is harmless: the sandbox recreates Data/Library on next launch, so
# targeting Data's contents gives a clean profile without the "Operation not
# permitted" noise.
if [ -d "$CONTAINER/Data" ]; then
    find "$CONTAINER/Data" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    echo "Cleared $CONTAINER/Data"
else
    echo "Nothing to clear."
fi

if [ "$CLEAN_BUILD" -eq 1 ]; then
    rm -rf "$HOME/Library/Developer/Xcode/DerivedData/"Chord-*
    rm -rf "$(dirname "$0")/../Packages/.build"
    echo "Cleared build artifacts."
fi

echo "Done. $APP_NAME will start with a fresh profile on next launch."
