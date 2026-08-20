#!/bin/bash
# Wipe all of Chord's user data for a clean-slate profile (BROWSER_SPEC 3.3).
#
# Chord ships unsandboxed (see ChordApp/Chord.entitlements), so user state lives
# in the real Application Support folder plus WebKit's store and the preferences
# plist. The old sandbox container may still hold a leftover copy on machines
# that ran a sandboxed build, so it is cleared too.
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
SUPPORT="$HOME/Library/Application Support/$APP_NAME"
WEBKIT="$HOME/Library/WebKit/$BUNDLE_ID"
PREFS="$HOME/Library/Preferences/$BUNDLE_ID.plist"

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
for path in "$SUPPORT" "$WEBKIT" "$PREFS"; do
    if [ -e "$path" ]; then
        echo "  $path"
    else
        echo "  $path (nothing there yet)"
    fi
done
if [ -d "$CONTAINER/Data" ] && [ -n "$(ls -A "$CONTAINER/Data" 2>/dev/null)" ]; then
    echo "  $CONTAINER/Data (leftover sandbox container)"
fi
[ "$CLEAN_BUILD" -eq 1 ] && echo "  + build artifacts (DerivedData/Chord-*, Packages/.build)"

if [ "$ASSUME_YES" -ne 1 ]; then
    printf "Type 'y' to continue: "
    read -r reply
    [ "$reply" = "y" ] || { echo "Aborted."; exit 1; }
fi

# Quit the app first, or open files keep files half-alive and the delete fails.
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -x Chord     >/dev/null 2>&1 || true   # in case it launched as the target name
sleep 1

rm -rf "$SUPPORT" "$WEBKIT" "$PREFS" 2>/dev/null || true

# The old container root and its metadata plist are managed by macOS's
# containermanagerd and refuse deletion without Full Disk Access. Leaving the
# empty shell is harmless; clearing Data's contents is what resets the profile.
if [ -d "$CONTAINER/Data" ]; then
    find "$CONTAINER/Data" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    echo "Cleared $CONTAINER/Data"
fi

if [ "$CLEAN_BUILD" -eq 1 ]; then
    rm -rf "$HOME/Library/Developer/Xcode/DerivedData/"Chord-*
    rm -rf "$(dirname "$0")/../Packages/.build"
    echo "Cleared build artifacts."
fi

echo "Done. $APP_NAME will start with a fresh profile on next launch."