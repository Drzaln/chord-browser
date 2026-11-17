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
| Startup, launch to first commit, less the first page's network wait | 800 ms | §6.1's ceiling; measured 281 ms on 2026-11-17 (880 ms first commit, 599 ms of it the site) | `scripts/startup-gate.sh` (every `release.sh`) |
| Startup, Chord's own work (launch to first-load-start) | 400 ms | §6.1's aim; measured about 270 ms | same |

The reviewed intervals: YouTube's ad check runs four times a second only
while an ad is up, plus a 2 s backup for missed events; Geolocation polls
only while a page watches the position.

## Startup

Decided 2026-11-12 (c1k.17): §6.1's "cold launch to first interactive frame"
is judged at **first commit**, the first bytes of the first page on screen.
It used to be read at `first-paint`, which is `didFinish` of the restored
page and so belongs to the site and the network: the installed 1.24.1 logged
559 to 6,748 ms across nine everyday launches with the same build.

`scripts/startup-gate.sh` (c1k.19) builds the Release app into `.build-perf`,
relaunches it five times on the everyday profile
(`scripts/perf-baseline.sh startup`) and fails when a median passes its
budget: launch to `first-load-start` (Chord's own work) over 400 ms, or
launch to `first-commit` over 800 ms. `release.sh` runs it on every release
with nobody opting in; `CHORD_SKIP_STARTUP=1` skips it.
`CHORD_PERF=1 scripts/prepush.sh` runs the same gate by hand. A daily push
does not run it, because it quits and relaunches the running Chord (and puts
it back after).

Amended 2026-11-17 (42j): first commit is judged **less the first page's
network wait**. The first page is whichever tab the session restores, so the
number moved with the site: the same 1.27.1 build measured 448 to 651 ms on
2026-11-16 and 841 to 1,117 ms a day later, when the restored tab was a
signed-in page whose server takes about half a second to answer, and a
release with no startup change failed the gate. At first commit Chord now
asks that page for its navigation timing and logs
`perf first-network-wait <ms>`: DNS lookup, connection and TLS, and request
sent to first byte. The gate takes that off first commit before comparing it
with 800 ms. Time before the lookup starts (the network process coming up,
content rules loading) is not taken off: that is the launch's own cost. When
fewer than three runs report a wait (a page with no navigation timing), the
whole first commit is judged, as before.

Do not browse while it runs. A launch into a blank window (no selected tab)
loads no page; that run is not counted, and fewer than three counted runs
reports "not measured" and passes with a warning.

Each run also prints where the time went, in ms since launch: `env-ready`,
`restore-start`, `restore-done`, `first-view`, `first-load-start`,
`first-commit`, `extensions-start`, `first-paint`, and after them the medians,
including `network-wait` and `commit-less-network`.
