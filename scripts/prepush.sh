#!/bin/bash
# Local CI (BROWSER_SPEC 7.6): build every package, run every test, build the
# app. Warnings are errors, from day one, before there are any.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Building packages"
swift build --package-path Packages -Xswiftc -warnings-as-errors

echo "==> Running tests"
swift test --package-path Packages

echo "==> Building app"
# Not piped straight into grep: `set -e` takes the *pipeline's* status, which is
# grep's, and `|| true` swallowed even that — so a failed app build still
# printed "OK". Capture, then report, then propagate xcodebuild's own status.
build_log="$(mktemp -t chord-build)"
trap 'rm -f "$build_log"' EXIT

if xcodebuild \
    -project Browser.xcodeproj \
    -scheme Browser \
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
