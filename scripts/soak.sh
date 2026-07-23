#!/bin/bash
# The 30-minute soak that BROWSER_SPEC §8 gates every milestone on, and §6.7
# describes: 20 tabs, 3 Spaces, repeated Space switching, footprint recorded at
# start and end. Growth over the run means a leak.
#
# Until now this was driven by hand from SMOKE.md, which is why it had been run
# exactly once. Usage:
#
#   scripts/soak.sh seed     # quit the app and write the 3-Space, 20-tab fixture
#   scripts/soak.sh run      # drive and sample a running app (default 30 min)
#   SOAK_MINUTES=5 scripts/soak.sh run
#
# `seed` writes the fixture straight into browser.sqlite rather than driving 20
# new-tab commands through the UI. That is deliberate: it makes the soak start
# from a *restored* session, which is the state the budgets are written against
# and the one that exercises lazy restore (§6.2 — N saved tabs must create 0
# web views).
set -euo pipefail

APP_SUPPORT=~/"Library/Containers/com.rizal.browser/Data/Library/Application Support/Browser"
DB="$APP_SUPPORT/browser.sqlite"
MINUTES="${SOAK_MINUTES:-30}"

# Sites that are cheap, stable, and not ours to hammer.
URLS=(
    "https://example.com" "https://www.iana.org" "https://developer.apple.com"
    "https://www.rfc-editor.org" "https://swift.org" "https://www.unicode.org"
    "https://httpbin.org" "https://www.w3.org"
)

seed() {
    osascript -e 'quit app "Browser"' 2>/dev/null || true
    sleep 3

    [ -f "$DB" ] || { echo "no database at $DB — launch the app once first" >&2; exit 1; }

    # `.backup`, never `cp`. GRDB runs in WAL mode, so the recent commits live
    # in browser.sqlite-wal and a plain copy of the main file alone is stale.
    # Restoring such a copy next to the *newer* WAL replays it over an older
    # database and corrupts it — that is not hypothetical, it happened here on
    # 2026-07-23 and cost a `.recover` pass. `.backup` checkpoints into one
    # self-contained file.
    rm -f "$DB.presoak"
    sqlite3 "$DB" ".backup '$DB.presoak'"
    echo "backed up to $DB.presoak — restore it with: $0 restore"

    # A third Space, if the fixture does not already have one. The data store
    # identifier is what gives it isolated cookies (§3.3); a fresh UUID means a
    # fresh store, created lazily on first use.
    local third
    third=$(sqlite3 "$DB" "select id from space where sortIndex = 2;")
    if [ -z "$third" ]; then
        third=$(uuidgen)
        sqlite3 "$DB" "insert into space values (
            '$third', 'Soak', 'flame', '#3EC7A0,#1E88E5', '$(uuidgen)', 2, 0
        );"
    fi

    local spaces=()
    while IFS= read -r s; do spaces+=("$s"); done < <(sqlite3 "$DB" \
        "select id from space order by sortIndex;")

    sqlite3 "$DB" "delete from tab;"  # panes cascade

    local now
    now=$(python3 -c 'import time; print(time.time() - 978307200)')  # Core Data epoch

    # 21 tabs: 7 per Space, one of them a 4-pane split. Split view and Little
    # Arc are what M5 added, and both add live web views — a 4-pane tab is 4 at
    # once — so a soak that predates them proves nothing about them.
    local n=0
    for space in "${spaces[@]}"; do
        for i in $(seq 0 6); do
            local tabID paneCount
            tabID=$(uuidgen)
            paneCount=1
            [ "$i" -eq 3 ] && paneCount=4

            local firstPane="" p
            for p in $(seq 0 $((paneCount - 1))); do
                local paneID url fraction
                paneID=$(uuidgen)
                url="${URLS[$((n % ${#URLS[@]}))]}"
                fraction=$(python3 -c "print(1.0 / $paneCount)")
                [ -z "$firstPane" ] && firstPane="$paneID"
                sqlite3 "$DB" "insert into pane values (
                    '$paneID', '$tabID', $p, '$url', '', null, $fraction
                );"
                n=$((n + 1))
            done

            sqlite3 "$DB" "insert into tab values (
                '$tabID', 'ephemeral', $i, '$firstPane', $now, $now, '$space'
            );"
        done
    done

    echo "seeded: $(sqlite3 "$DB" 'select count(*) from space;') Spaces, \
$(sqlite3 "$DB" 'select count(*) from tab;') tabs, \
$(sqlite3 "$DB" 'select count(*) from pane;') panes"
    echo "now launch the app, let it settle, then: scripts/soak.sh run"
}

# phys_footprint in MB, for the app process and for the app plus every WebKit
# helper it owns. `footprint` reports the same number the debug overlay shows.
footprint_mb() {
    # "Browser [123]: 64-bit    Footprint: 38 MB (16384 bytes per page)".
    # The unit really does vary — helper processes report KB — so normalise it
    # rather than trusting MB.
    footprint -p "$1" 2>/dev/null | awk '
        /Footprint:/ {
            for (i = 1; i <= NF; i++) if ($i == "Footprint:") {
                v = $(i + 1); u = $(i + 2)
                if (u == "KB") v /= 1024
                else if (u == "GB") v *= 1024
                printf "%d\n", v
                exit
            }
        }'
}

run() {
    local pid
    pid=$(pgrep -x Browser | head -1)
    [ -n "$pid" ] || { echo "Browser is not running" >&2; exit 1; }

    local samples="/tmp/soak-$(date +%H%M%S).tsv"
    echo -e "minute\tapp_mb\ttotal_mb" | tee "$samples"

    local total_start
    total_start=$(total_mb "$pid")
    echo -e "0\t$(footprint_mb "$pid")\t$total_start" | tee -a "$samples"

    local endAt=$((SECONDS + MINUTES * 60))
    local nextSample=$((SECONDS + 60))
    local space=1
    while [ $SECONDS -lt $endAt ]; do
        # Cmd+1...3: a Space switch tears down and revives web views, which is
        # where a leak would show.
        osascript -e "tell application \"System Events\" to tell process \"Browser\" \
            to keystroke \"$space\" using command down" 2>/dev/null || true
        space=$(( space % 3 + 1 ))
        sleep 4

        if [ $SECONDS -ge $nextSample ]; then
            echo -e "$(( (SECONDS) / 60 ))\t$(footprint_mb "$pid")\t$(total_mb "$pid")" \
                | tee -a "$samples"
            nextSample=$((SECONDS + 60))
        fi
    done

    echo
    echo "samples in $samples"
    echo "compare first and last rows; growth over the run means a leak (§6.7)."
    echo "for idle CPU, let the app settle 3-4 minutes first and measure a"
    echo "cputime delta, not ps %cpu — see SMOKE.md."
}

# The app plus every WebKit helper process. Content processes are the dominant
# cost (§6.2), and the app process alone hides them entirely.
total_mb() {
    local pids
    pids=$(pgrep -x Browser; pgrep -f "com.apple.WebKit" || true)
    local sum=0 p mb
    for p in $pids; do
        mb=$(footprint_mb "$p")
        [ -n "$mb" ] && sum=$((sum + mb))
    done
    echo "$sum"
}

restore() {
    osascript -e 'quit app "Browser"' 2>/dev/null || true
    sleep 3
    [ -f "$DB.presoak" ] || { echo "no $DB.presoak to restore" >&2; exit 1; }

    # The sidecars belong to the database being replaced, not to the one coming
    # back. Leaving them is exactly how the restore corrupts what it restores.
    rm -f "$DB" "$DB-wal" "$DB-shm"
    cp "$DB.presoak" "$DB"
    sqlite3 "$DB" "pragma integrity_check;"
    echo "restored; the soak fixture is gone"
}

case "${1:-}" in
    seed)    seed ;;
    run)     run ;;
    restore) restore ;;
    *) echo "usage: $0 {seed|run|restore}" >&2; exit 1 ;;
esac
