#!/usr/bin/env bash
# c1k.1: the perf baseline harness. Chord against Safari on the tab set in
# docs/perf/TABSET.md. Every c1k task reports before/after numbers from here.
#
#   scripts/perf-baseline.sh startup [--app Safari]     median cold start → first paint, 5 runs
#   scripts/perf-baseline.sh switch                      median tab switch, last 20 switches
#   scripts/perf-baseline.sh idle <seconds> [--app Safari]   CPU / wakeups / energy (sudo)
#   scripts/perf-baseline.sh footprint [--app Safari] [--plist <file>]
#                                                        memory by process group (sudo, or
#                                                        the processes an idle run saved)
#   scripts/perf-baseline.sh dump [--app Safari]         one raw powermetrics sample, for debugging
#
# CHORD_APP=/path/to/Chord.app picks the build (default: the Debug build in
# DerivedData). Measure a Release build for numbers that go in a BASELINE doc.
#
# Chord's WebKit helpers are XPC services whose parent is launchd, so `ps`
# cannot tell them from Safari's. They share the app's coalition, which only
# powermetrics (root) reports; idle and footprint use it to find them.
set -euo pipefail

SUBSYSTEM="com.rizal.chord"
CHORD_ID="com.rizal.chord"
SAFARI_ID="com.apple.Safari"

die() { echo "error: $*" >&2; exit 1; }

chord_app() {
    if [[ -n "${CHORD_APP:-}" ]]; then echo "$CHORD_APP"; return; fi
    local found
    found=$(find "$HOME"/Library/Developer/Xcode/DerivedData -maxdepth 5 -path "*/Build/Products/Debug/Chord.app" 2>/dev/null | head -1)
    [[ -n "$found" ]] || die "no Chord.app; build it or set CHORD_APP"
    echo "$found"
}

# Which app a subcommand measures: Chord unless `--app Safari` follows.
target="Chord"
plist=""
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) target="${2:?--app needs a name}"; shift 2 ;;
        --plist) plist="${2:?--plist needs a file}"; shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
set -- "${args[@]+"${args[@]}"}"
bundle_id() { [[ "$target" == "Safari" ]] && echo "$SAFARI_ID" || echo "$CHORD_ID"; }

# Chord's perf notices since a `log show --start` time, as "<epoch-ms> perf <event> [id]".
perf_lines() {
    /usr/bin/log show --style compact --start "$1" \
        --predicate "subsystem == \"$SUBSYSTEM\" AND eventMessage BEGINSWITH \"perf \"" 2>/dev/null |
    /usr/bin/python3 -c '
import sys, re, datetime
for line in sys.stdin:
    m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\S*\s.*?\] (perf .*)$", line.rstrip())
    if not m: continue
    t = datetime.datetime.strptime(m.group(1)[:26], "%Y-%m-%d %H:%M:%S.%f")
    print(int(t.timestamp() * 1000), m.group(2))
'
}

median() { sort -n | awk '{a[NR]=$1} END {if (NR==0) {print "n/a"; exit} m=(NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2; print m}'; }

cmd_startup() {
    [[ "$target" == "Chord" ]] || die "startup reads Chord's own signposts; time Safari by hand"
    local app; app=$(chord_app)
    local results=()
    for run in 1 2 3 4 5; do
        osascript -e 'tell application id "'"$CHORD_ID"'" to quit' >/dev/null 2>&1 || true
        while pgrep -x Chord >/dev/null; do sleep 0.5; done
        sleep 2
        local start; start=$(date "+%Y-%m-%d %H:%M:%S")
        open "$app"
        sleep 15
        local ms
        ms=$(perf_lines "$start" | awk '
            $3=="launch" && !l {l=$1}
            $3=="first-paint" && l && !p {p=$1}
            END {if (l && p) print p-l}')
        echo "run $run: ${ms:-no first-paint logged} ms"
        [[ -n "$ms" ]] && results+=("$ms")
    done
    printf '%s\n' "${results[@]+"${results[@]}"}" | median | sed 's/^/startup median ms: /'
}

cmd_switch() {
    [[ "$target" == "Chord" ]] || die "switch reads Chord's own signposts; time Safari by hand"
    local start; start=$(date -v-60M "+%Y-%m-%d %H:%M:%S")
    perf_lines "$start" | awk '
        $3=="tab-switch-start" {s[$4]=$1}
        $3=="tab-switch-end" && ($4 in s) {print $1-s[$4]; delete s[$4]}' |
        tail -20 | tee /dev/stderr | median | sed 's/^/tab switch median ms (last 20): /'
}

# One powermetrics run as NUL-separated plists, with coalitions and energy.
# Root comes from sudo in a terminal, or else from macOS's password dialog,
# asked once for the run, so the harness can also be driven by a script.
powermetrics_plist() {
    local samples="$1"
    local command="/usr/bin/powermetrics --samplers tasks --show-process-coalition --show-process-energy -f plist -i 1000 -n $samples"
    if [[ $EUID -eq 0 ]] || sudo -n true 2>/dev/null || [[ -t 0 ]]; then
        sudo $command
        return
    fi
    local out; out=$(mktemp -t chord-powermetrics)
    osascript -e "do shell script \"$command > '$out'; chmod 644 '$out'\" with administrator privileges with prompt \"Chord perf baseline: powermetrics for ${samples}s needs your password.\"" >/dev/null
    cat "$out"; rm -f "$out"
}

# Reads powermetrics plists on stdin; prints per-group averages for one
# coalition, or the group's pids with --pids.
summarize() {
    # The program goes in with -c: stdin carries the plists.
    local program
    program=$(cat <<'PY'
import sys, plistlib
bundle, mode = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
def group(name):
    n = name.lower()
    if "webcontent" in n or "web content" in n: return "WebContent"
    if "networking" in n: return "Networking"
    if ".gpu" in n or "graphics" in n: return "GPU"
    if "extension" in n: return "Extension"
    if "vtdecoder" in n or "vtencoder" in n or "media" in n: return "Media"
    if n in ("chord", "safari"): return "UI"
    return "Other"
def field(task, *keys):
    for k in keys:
        if k in task: return float(task[k])
    return 0.0
samples, totals, pids, counts = 0, {}, {}, {}
last = {}
for chunk in sys.stdin.buffer.read().split(b"\x00"):
    chunk = chunk.strip()
    if not chunk: continue
    try: sample = plistlib.loads(chunk)
    except Exception: continue
    samples += 1
    for c in sample.get("coalitions", []):
        if c.get("name") != bundle: continue
        seen = {}
        last = {}
        for t in c.get("tasks", []):
            g = group(t.get("name", ""))
            pids.setdefault(g, set()).add(t.get("pid"))
            last.setdefault(g, set()).add(t.get("pid"))
            seen[g] = seen.get(g, 0) + 1
            row = totals.setdefault(g, [0.0, 0.0, 0.0, 0.0])
            row[0] += field(t, "cputime_ms_per_s")
            row[1] += field(t, "intr_wakeups_per_s")
            row[2] += field(t, "idle_wakeups_per_s", "pkg_idle_wakeups_per_s")
            row[3] += field(t, "energy_impact_per_s", "energy_impact")
        for g, n in seen.items(): counts[g] = max(counts.get(g, 0), n)
if mode == "--pids":
    # The last sample's processes: WebContent processes come and go.
    for g, ps in last.items():
        for p in ps: print(g, p)
    sys.exit(0)
if not samples or not totals:
    sys.exit(f"no samples for coalition {bundle}; is it running? try `dump` to see the raw output")
print(f"{bundle}: {samples} samples, averages per second")
print(f"{'group':<12}{'procs':>6}{'CPU ms/s':>11}{'intr wk/s':>11}{'pkg wk/s':>11}{'energy':>9}")
sums = [0.0] * 4
for g in ("UI", "WebContent", "Networking", "GPU", "Media", "Extension", "Other"):
    if g not in totals: continue
    avg = [v / samples for v in totals[g]]
    sums = [a + b for a, b in zip(sums, avg)]
    print(f"{g:<12}{counts.get(g, 0):>6}{avg[0]:>11.1f}{avg[1]:>11.1f}{avg[2]:>11.1f}{avg[3]:>9.1f}")
print(f"{'total':<12}{'':>6}{sums[0]:>11.1f}{sums[1]:>11.1f}{sums[2]:>11.1f}{sums[3]:>9.1f}")
PY
)
    /usr/bin/python3 -c "$program" "$(bundle_id)" "$@"
}

cmd_idle() {
    local seconds="${1:?idle needs <seconds>}"
    local raw; raw="${TMPDIR:-/tmp}/chord-idle-$target-$(date +%Y%m%d-%H%M%S).plist"
    echo "sampling $target for ${seconds}s — don't touch anything"
    powermetrics_plist "$seconds" > "$raw"
    summarize < "$raw"
    echo "raw samples: $raw (footprint --plist reads its processes)"
}

cmd_footprint() {
    local pids
    if [[ -n "$plist" ]]; then pids=$(summarize --pids < "$plist")
    else pids=$(powermetrics_plist 1 | summarize --pids); fi
    [[ -n "$pids" ]] || die "no $target processes found"
    echo "$target memory footprint by group (MB)"
    echo "$pids" | while read -r group pid; do
        local bytes
        bytes=$(footprint -f bytes --noCategories -p "$pid" 2>/dev/null |
            awk '/phys_footprint:/ {print $2; exit}')
        echo "$group ${bytes:-0}"
    done | awk '{s[$1]+=$2; n[$1]++; t+=$2}
        END {for (g in s) printf "%-12s %4d procs %10.1f\n", g, n[g], s[g]/1048576
             printf "%-12s %15.1f\n", "total", t/1048576}'
}

cmd_dump() {
    local out="${TMPDIR:-/tmp}/chord-powermetrics-$(date +%s).plist"
    powermetrics_plist 1 > "$out"
    echo "raw sample in $out"
}

case "${1:-}" in
    startup) cmd_startup ;;
    switch) cmd_switch ;;
    idle) shift; cmd_idle "$@" ;;
    footprint) cmd_footprint ;;
    dump) cmd_dump ;;
    *) sed -n '2,10p' "$0"; exit 1 ;;
esac
