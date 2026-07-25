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

BUNDLE_ID="com.rizal.browser"   # keep in sync with PRODUCT_BUNDLE_IDENTIFIER
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

echo "This will PERMANENTLY delete all of $APP_NAME's data:"
echo "  $CONTAINER"
if [ ! -d "$CONTAINER" ]; then
    echo "  (already gone — nothing to delete)"
fi
[ "$CLEAN_BUILD" -eq 1 ] && echo "  + build artifacts (DerivedData/Browser-*, Packages/.build)"

if [ "$ASSUME_YES" -ne 1 ]; then
    printf "Type 'y' to continue: "
    read -r reply
    [ "$reply" = "y" ] || { echo "Aborted."; exit 1; }
fi

# Quit the app first, or open files keep the container half-alive.
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -x Browser     >/dev/null 2>&1 || true   # in case it launched as the target name
sleep 1

rm -rf "$CONTAINER"
echo "Deleted $CONTAINER"

if [ "$CLEAN_BUILD" -eq 1 ]; then
    rm -rf "$HOME/Library/Developer/Xcode/DerivedData/"Browser-*
    rm -rf "$(dirname "$0")/../Packages/.build"
    echo "Cleared build artifacts."
fi

echo "Done. $APP_NAME will start with a fresh profile on next launch."
