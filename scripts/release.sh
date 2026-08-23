#!/bin/bash
# Standard GitHub release — the one path from "push to GitHub" to a published
# release. Run this only after the feature work and its doc updates are already
# committed (see AGENTS.md → "Push to GitHub / release").
#
# Usage: ./scripts/release.sh <semver> [build-number]
#   semver  e.g. 1.5.0 — becomes MARKETING_VERSION / CFBundleShortVersionString
#                       and the v1.5.0 tag.
#   build   e.g. 19     — becomes CURRENT_PROJECT_VERSION / CFBundleVersion.
#                         Defaults to the current build + 1.
#
# What it does:
#   1. Refuses to run off `main` or with a dirty tree (feature + docs first).
#   2. Bumps the version and build in project.pbxproj + ChordApp/Info.plist.
#   3. Runs ./scripts/prepush.sh as the release gate (warnings are errors).
#   4. Commits the bump as "release: X (build Y)".
#   5. Tags v<semver> (must equal MARKETING_VERSION or the GitHub workflow's
#      build fails — it verifies the match and errors otherwise).
#   6. Pushes main and the tag; the tag push triggers the Release workflow,
#      which builds Chord.zip and publishes it as a GitHub Release (the
#      self-updater's source).
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?usage: ./scripts/release.sh <semver> [build-number]}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version must be x.y.z, got '$VERSION'" >&2
    exit 1
fi

CURRENT_BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION = ' Chord.xcodeproj/project.pbxproj \
    | grep -oE '[0-9]+')"
BUILD="${2:-$((CURRENT_BUILD + 1))}"

# --- Guard rails ------------------------------------------------------------

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
    echo "error: releases go out from main, not '$BRANCH'" >&2
    exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "error: working tree is not clean." >&2
    echo "       Commit the feature work and its doc updates first, then run release.sh." >&2
    git status --short >&2
    exit 1
fi

# --- Bump --------------------------------------------------------------------

echo "==> Bumping to $VERSION (build $BUILD)"

# project.pbxproj carries MARKETING_VERSION / CURRENT_PROJECT_VERSION twice
# (Debug + Release configs).
sed -i '' "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = $VERSION;/g" \
    Chord.xcodeproj/project.pbxproj
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $BUILD;/g" \
    Chord.xcodeproj/project.pbxproj

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" ChordApp/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" ChordApp/Info.plist

# The GitHub workflow fails the build if the tag != the app version, so check
# the same thing locally before committing.
APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" ChordApp/Info.plist)"
if [[ "$APP_VERSION" != "$VERSION" ]]; then
    echo "error: bump did not land — Info.plist says $APP_VERSION, expected $VERSION" >&2
    exit 1
fi

# --- Gate --------------------------------------------------------------------

echo "==> Release gate: prepush"
./scripts/prepush.sh

# --- Commit, tag, push -------------------------------------------------------

git add Chord.xcodeproj/project.pbxproj ChordApp/Info.plist
git commit -m "release: $VERSION (build $BUILD)"

TAG="v$VERSION"
if git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
    echo "error: tag $TAG already exists" >&2
    exit 1
fi
git tag "$TAG"

echo "==> Pushing main + $TAG"
git push origin main
git push origin "$TAG"

echo "==> Released $TAG — the GitHub Release workflow is building Chord.zip"
echo "==> Next: reindex the codebase (codebase-memory-mcp index_repository)."