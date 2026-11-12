#!/usr/bin/env bash
# c1k.16: what Chord costs while hidden and minimized, and whether bringing it
# back starts the display-link spin (c1k.13).
#
#   scripts/perf-hidden.sh [seconds-per-phase]      default 300; the bead asks for 900
#
# No sudo. It samples CPU and idle wakeups with `top` for the Chord process
# (the window process, where the spin shows) and for every WebKit helper.
# WebKit helpers belong to launchd, so they cannot be told from Safari's:
# QUIT SAFARI FIRST, and do not use the Mac while a phase runs.
#
# You drive the phases; it tells you what to do and waits for Return:
#   front, hidden (Cmd-H), front again, minimized (Cmd-M), front again.
# The two "front again" phases are the ones that matter for the spin: the
# window process should stay under ~30 wakeups/s. Hundreds means the spin.
#
# Run it twice on a Release build with the docs/perf/TABSET.md tabs open and
# nothing playing: once with Settings → General → Background Tabs →
# "Suspend them only while Chord is hidden or minimized" off, once on.
set -euo pipefail

SECS="${1:-300}"
pgrep -x Safari >/dev/null && { echo "error: quit Safari first (its WebKit processes look like Chord's)" >&2; exit 1; }
chord=$(pgrep -x Chord | head -1 || true)
[[ -n "$chord" ]] || { echo "error: Chord is not running" >&2; exit 1; }

sample() {
    local label="$1"
    local pids=("$chord")
    while read -r pid; do pids+=("$pid"); done < <(pgrep -f 'com\.apple\.WebKit\.(WebContent|GPU|Networking)' || true)
    local args=()
    for pid in "${pids[@]}"; do args+=(-pid "$pid"); done
    # Two samples: top's first is since process start, the second is the interval.
    top -l 2 -s "$SECS" -c d -stats pid,command,cpu,idlew "${args[@]}" 2>/dev/null |
    awk -v chord="$chord" -v secs="$SECS" -v label="$label" '
        /^PID/ {block++; next}
        block == 2 && NF >= 4 {
            cpu = $(NF-1); wake = $NF
            total_cpu += cpu; total_wake += wake; n++
            if ($1 == chord) {ui_cpu = cpu; ui_wake = wake}
        }
        END {
            printf "%-16s window process: %5.1f%% CPU, %6.1f wakeups/s | all %d processes: %5.1f%% CPU (%.0f ms/s), %6.1f wakeups/s\n",
                label, ui_cpu, ui_wake / secs, n, total_cpu, total_cpu * 10, total_wake / secs
        }'
}

phase() {
    local label="$1" instruction="$2"
    printf '\n%s\n  then press Return and leave the Mac alone for %s s… ' "$instruction" "$SECS"
    read -r _
    sleep 5   # let the window settle
    sample "$label"
}

echo "Chord pid $chord, $SECS s per phase."
phase "front"            "Bring Chord to the front with a normal page showing."
phase "hidden"           "Hide Chord with Cmd-H."
phase "front after hide" "Bring Chord back (click its Dock icon)."
phase "minimized"        "Minimize the Chord window with Cmd-M."
phase "front after min"  "Restore the window from the Dock."
echo
echo "Record the table in docs/perf, next to BASELINE-2026-10-31-c1k11.md."
