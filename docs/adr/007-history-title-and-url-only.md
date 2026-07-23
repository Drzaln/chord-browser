# 007 — History is title and URL only

**Status:** accepted (M3) — resolves an open decision in BROWSER_SPEC 12

The command bar ranks across history (4.4), so M3 had to build history at all.
The open question was whether it should be full-text searchable over page
content or title and URL only.

Title and URL. The recall you actually want from a command bar is "that GitHub
page" or "the docs I had open yesterday", and both are title-or-URL matches.
Full-text buys the rarer "the article that mentioned X" at a price the §6
budgets do not have room for: a text-extraction pass on every page load, an
FTS5 index to maintain, and a database that grows with content rather than with
visits.

One row per URL, upserted: revisiting bumps `visitCount` and `lastVisitedAt`
rather than appending. That keeps the table proportional to distinct pages
visited, and gives the ranker a frequency signal for free.

This is deliberately not a one-way door. Adding FTS later is a new table and a
new migration, not a reshape of `historyEntry` — the existing rows stay exactly
as they are, and the ranker gains a source rather than changing shape. If the
title-and-URL version turns out to be frustrating in daily use, revisit it then
with a real complaint to aim at rather than a guess.

Ranking weights live in `CommandBarRanking` and are pure functions, so tuning
them is a test change, not a UI change.
