# 002 — Live web views are capped at 12, LRU-evicted

**Status:** accepted (M1)

Each live `WKWebView` costs a content process, a networking allocation, and
GPU-backed layers. That single fact dominates the memory budgets in
BROWSER_SPEC 6.1 — everything else in the app layer is noise next to it. The cap
is therefore a correctness property, not a tuning knob to revisit later.

Twelve is the spec's number and we kept it, but it is a guess until measured.
The 30-minute soak at each milestone is what will confirm or move it. What
matters more than the number is the mechanism: the pool captures
`interactionState` before tearing a view down, so reviving an evicted pane
restores scroll position and back/forward history with no network traffic. A
cheap revival is what makes an aggressive cap tolerable.

Two rules the implementation enforces beyond the plain cap. The most recently
used view is never evicted, so the cap can never take away the page the user is
looking at — with a capacity of 1 the pool simply holds one view. And memory
pressure overrides the steady state: `.warning` drops the cap to 6, `.critical`
to 3, and returning to `.normal` restores it. Those transitions run through the
same eviction path, so there is one code path to reason about.

Restore is deliberately lazy and tested as such: opening a profile with twenty
saved tabs must create zero web views. Titles and favicons come from the model;
a view is built on first activation and not before.
