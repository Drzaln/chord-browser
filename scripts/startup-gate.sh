#!/usr/bin/env bash
# c1k.19: the startup budget as a gate. Builds the Release app, relaunches it
# five times on the everyday profile, and fails when the medians pass the
# budget (BROWSER_SPEC §6.1, docs/perf/BUDGETS.md):
#
#   launch → first-load-start   Chord's own work    <= OWN_BUDGET_MS
#   launch → first-commit       first bytes shown   <= COMMIT_BUDGET_MS
#
# First commit is judged with the first page's network wait taken off (42j).
# The first page is whichever tab the session restores, and one that takes
# 500 ms to answer failed a release whose code had not changed. Chord logs
# what that page spent between starting its fetch and its first byte, and
# that much is the site's, not the launch's. A page that reports no timing is
# judged on the whole first commit, as before.
#
# It quits the running Chord and puts it back afterwards. Do not use the
# browser while it runs: a launch into a blank window loads no page and is
# not counted, and fewer than MIN_RUNS counted runs means "not measured",
# which warns but does not fail (a blank session is not a slow launch).
set -euo pipefail
cd "$(dirname "$0")/.."

OWN_BUDGET_MS=400      # §6.1's aim; measured about 270 on 2026-11-10
COMMIT_BUDGET_MS=800   # §6.1's ceiling; 281 less the network on 2026-11-17
MIN_RUNS=3

echo "==> Startup gate: building Release"
build_log="$(mktemp -t chord-perf-build)"
trap 'rm -f "$build_log"' EXIT
if ! xcodebuild -project Chord.xcodeproj -scheme Chord -configuration Release \
        -destination 'platform=macOS' -derivedDataPath .build-perf build > "$build_log" 2>&1; then
    grep -E "error:|BUILD" "$build_log" || true
    echo "==> startup gate: Release build FAILED" >&2
    exit 1
fi

echo "==> Startup gate: measuring (${STARTUP_RUNS:-5} relaunches)"
out=$(CHORD_APP="$PWD/.build-perf/Build/Products/Release/Chord.app" scripts/perf-baseline.sh startup)
echo "$out"
valid=$(echo "$out" | sed -n 's/^startup valid runs: //p')
commit=$(echo "$out" | sed -n 's/^startup median ms: //p')
own=$(echo "$out" | sed -n 's/^startup own-work median ms: //p')
timed=$(echo "$out" | sed -n 's/^startup network-wait runs: //p')
net=$(echo "$out" | sed -n 's/^startup commit-less-network median ms: //p')
waited=$(echo "$out" | sed -n 's/^startup network-wait median ms: //p')

if [[ "${valid:-0}" -lt "$MIN_RUNS" ]]; then
    echo "==> startup gate: NOT MEASURED (${valid:-0} counted runs; open a tab and rerun scripts/startup-gate.sh)" >&2
    exit 0
fi
over() { awk -v m="$1" -v b="$2" 'BEGIN { exit !(m == "" || m == "n/a" || m > b) }'; }
fail=0
if over "$own" "$OWN_BUDGET_MS"; then
    echo "startup own work ${own} ms is over ${OWN_BUDGET_MS} ms" >&2; fail=1
fi
judged="$commit"
note="no network timing from the first page; the whole first commit is judged"
if [[ "${timed:-0}" -ge "$MIN_RUNS" ]]; then
    judged="$net"
    note="first commit ${commit} ms less ${waited} ms waiting on the site"
fi
if over "$judged" "$COMMIT_BUDGET_MS"; then
    echo "startup first commit ${judged} ms is over ${COMMIT_BUDGET_MS} ms (${note})" >&2; fail=1
fi
if [[ "$fail" == "1" ]]; then
    echo "startup over the perf budget: see docs/perf/BUDGETS.md" >&2
    exit 1
fi
echo "==> startup gate OK: own work ${own} ms (<= ${OWN_BUDGET_MS}), first commit ${judged} ms (<= ${COMMIT_BUDGET_MS}; ${note})"
