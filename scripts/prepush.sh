#!/bin/bash
# Local CI (BROWSER_SPEC 7.6): build every package, run every test, build the
# app. Warnings are errors, from day one, before there are any.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Building packages"
swift build --package-path Packages -Xswiftc -warnings-as-errors

echo "==> Running tests"
# One target at a time, serial, each under a time limit. A whole-suite run
# could stall for good partway through (x4b: the test process sits idle with
# nothing left to run), and a gate that hangs is worse than one that fails.
# A target that stalls is run once more; a second stall, or any failure,
# stops the gate with the target's name and its output.
# The product code was held to warnings-as-errors above; tests are not (yet).
swift build --package-path Packages --build-tests
test_log="$(mktemp -t chord-test)"
trap 'rm -f "$test_log"' EXIT
target_limit="${CHORD_TEST_TIMEOUT:-180}"

run_target() {
    /usr/bin/timeout "$target_limit" swift test --package-path Packages \
        --skip-build --no-parallel --filter "^$1\." > "$test_log" 2>&1
}

for dir in Packages/Tests/*Tests; do
    target="$(basename "$dir")"
    status=0
    run_target "$target" || status=$?
    if [[ $status -eq 124 ]]; then
        echo "    $target stalled after ${target_limit}s, running it once more"
        pkill -f "swiftpm-testing-helper.*$target" || true
        status=0
        run_target "$target" || status=$?
    fi
    if [[ $status -ne 0 ]]; then
        pkill -f "swiftpm-testing-helper.*$target" || true
        tail -n 60 "$test_log"
        [[ $status -eq 124 ]] && echo "==> $target stalled twice" || echo "==> $target FAILED"
        exit 1
    fi
    echo "    $target: $(grep -E 'Test run with' "$test_log" | tail -1 | sed 's/^[^T]*//')"
done

# The real-extension matrix needs the Chrome Web Store and the Mac's
# extensions, so it is not part of the default gate. `CHORD_REAL_EXTENSIONS=1`
# opts in for a release sweep.
if [[ "${CHORD_REAL_EXTENSIONS:-0}" == "1" ]]; then
    echo "==> Probing real Chrome extensions"
    CHORD_REAL_EXTENSIONS=1 swift test \
        --package-path Packages --filter RealExtensionProbeTests --no-parallel
fi

# Launch to first paint against its budget (docs/perf/BUDGETS.md). Opt-in:
# launch timing is noisy on a shared machine. Needs a Release build.
STARTUP_BUDGET_MS=2545  # 2213 ms baseline (2026-10-30) × 1.15
if [[ "${CHORD_PERF:-0}" == "1" ]]; then
    echo "==> Startup against its budget"
    median=$(scripts/perf-baseline.sh startup | sed -n 's/^startup median ms: //p')
    echo "startup median ${median} ms, budget ${STARTUP_BUDGET_MS} ms"
    if ! awk -v m="$median" -v b="$STARTUP_BUDGET_MS" 'BEGIN { exit !(m != "" && m != "n/a" && m <= b) }'; then
        echo "startup over the perf budget: see docs/perf/BUDGETS.md" >&2
        exit 1
    fi
fi

echo "==> Building app"
# Not piped straight into grep: `set -e` takes the *pipeline's* status, which is
# grep's, and `|| true` swallowed even that — so a failed app build still
# printed "OK". Capture, then report, then propagate xcodebuild's own status.
build_log="$(mktemp -t chord-build)"
trap 'rm -f "$build_log" "$test_log"' EXIT

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
