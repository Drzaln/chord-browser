# Perf tab set (c1k)

The fixed workload every c1k measurement runs on, so runs are comparable.
Numbers go in `BASELINE-<date>.md`, made with `scripts/perf-baseline.sh`.

## Chord

**Space A — 6 tabs**

1. A YouTube video of 10 min or more, **playing**
   (e.g. `https://www.youtube.com/watch?v=aqz-KE-bpKQ`).
2. A second YouTube video, **paused**.
3. `https://mail.google.com` (signed in), or another heavy SPA without a login.
4. `https://github.com/apple/swift`
5. `https://en.wikipedia.org/wiki/Web_browser`
6. `https://example.com`

**Space B — 4 tabs**

1. `https://www.theverge.com`
2. `https://developer.apple.com/documentation/webkit`
3. `https://www.reddit.com`
4. `https://example.org`

**Extensions:** Bitwarden and uBlock Origin Lite, enabled in **both** Spaces.

## Safari

The same 10 URLs in one window, the same order. Extensions where they exist
for Safari: Bitwarden (Safari app extension) and uBlock Origin Lite (Safari
version). Write down in the BASELINE doc which ones were installed.

## Rules for a run

- Same power state (plugged in or battery) and brightness for both browsers.
- Other apps closed; Spotlight indexing settled (`mdutil -s /` idle).
- Load everything, then wait 5 minutes before idle measurements.
- The playing YouTube tab dominates energy: measure idle twice, with it
  playing and paused, so the other costs aren't hidden behind it.
- Speedometer 3.1 (`https://browserbench.org/Speedometer3.1/`) runs alone:
  quit and relaunch with only that tab, 3 runs, take the median.
- Measure a **Release** build of Chord (`CHORD_APP=…/Release/Chord.app`):
  Debug is unoptimised.

## Commands

```bash
scripts/perf-baseline.sh startup                 # median of 5, Chord only
scripts/perf-baseline.sh switch                  # after ~20 tab switches
scripts/perf-baseline.sh idle 300                # sudo; window in front
scripts/perf-baseline.sh idle 300 --app Safari
scripts/perf-baseline.sh footprint               # sudo; after the idle run
scripts/perf-baseline.sh footprint --app Safari
```

Extension worker processes (row h): extension workers are WebContent
processes too. Note the WebContent count from `footprint`, disable all
extensions in both Spaces, count again; the difference is the worker count.
