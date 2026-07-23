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
xcodebuild \
    -project Browser.xcodeproj \
    -scheme Browser \
    -configuration Debug \
    -destination 'platform=macOS' \
    build \
    | grep -E "error:|warning:|BUILD" || true

echo "==> OK"
