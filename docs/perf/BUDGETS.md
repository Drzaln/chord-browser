# Perf budgets (c1k.8)

What Chord adds on top of WebKit, held by tests so it can't creep back. The
numbers live in one place, `Packages/Sources/ChordTestSupport/PerfBudget.swift`.
To raise one, change the constant **and** say why in the commit; a test that
fails names this file.

| Budget | Now | Why it matters | Test |
|---|---:|---|---|
| User scripts on a default tab | 3 | each is parsed per frame or per page | `PerfBudgetTests.scriptBudget` |
| …of which in every frame | 1 | ad-heavy pages have dozens of iframes; the ten every-frame scripts are one bundle since c1k.3 | same |
| Their source size | 45,000 bytes (42,461 at c1k.8) | parse and compile cost per frame | same |
| `setInterval` in page scripts | YouTube 2, Geolocation 1, others 0 | a repeating timer wakes the page for as long as it is open | `PerfBudgetTests.reviewedIntervalsOnly` |
| `setInterval` in the extension shim | 0 | the shim runs in every extension page and worker | `ShimPerfBudgetTests.noIntervals` |
| Live intervals 2 s after a plain page loads | 0 | | `PerfBudgetTests.liveIntervals` |
| …on YouTube | 1 | the ad check's 2 s backup (c1k.5) | same |
| Startup, launch to first paint (opt-in) | 2,213 ms × 1.15 | measured on the 2026-10-30 baseline | `CHORD_PERF=1 scripts/prepush.sh` |

The reviewed intervals: YouTube's ad check runs four times a second only
while an ad is up, plus a 2 s backup for missed events; Geolocation polls
only while a page watches the position.

## Startup (opt-in)

Launch timing is noisy on a shared machine, so it isn't in the default
gate. `CHORD_PERF=1 scripts/prepush.sh` runs `scripts/perf-baseline.sh
startup` (median of 5 relaunches of the Release build) and fails above
`STARTUP_BUDGET_MS` in `scripts/prepush.sh`. Change that number the same way
as the others.
