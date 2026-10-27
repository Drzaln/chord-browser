#!/bin/bash
# Local CI (BROWSER_SPEC 7.6): build every package, run every test, build the
# app. Warnings are errors, from day one, before there are any.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Building packages"
swift build --package-path Packages -Xswiftc -warnings-as-errors

echo "==> Running tests"
# Serial: the parallel run can hang in ChordStoreTests waiting on testmanagerd.
swift test --package-path Packages --no-parallel

# The real-extension matrix needs the Chrome Web Store and the Mac's
# extensions, so it is not part of the default gate. `CHORD_REAL_EXTENSIONS=1`
# opts in for a release sweep.
if [[ "${CHORD_REAL_EXTENSIONS:-0}" == "1" ]]; then
    echo "==> Probing real Chrome extensions"
    CHORD_REAL_EXTENSIONS=1 swift test \
        --package-path Packages --filter RealExtensionProbeTests --no-parallel
fi

echo "==> Building app"
# Not piped straight into grep: `set -e` takes the *pipeline's* status, which is
# grep's, and `|| true` swallowed even that — so a failed app build still
# printed "OK". Capture, then report, then propagate xcodebuild's own status.
build_log="$(mktemp -t chord-build)"
trap 'rm -f "$build_log"' EXIT

if xcodebuild \
    -project Chord.xcodeproj \
    -scheme Chord \
    -configuration Debug \
    -destination 'platform=macOS' \
    build > "$build_log" 2>&1
then
    grep -E "warning:" "$build_log" || true
else
    grep -E "error:|BUILD" "$build_log" || true
    echo "==> app build FAILED"
    exit 1
fi

echo "==> OK"
