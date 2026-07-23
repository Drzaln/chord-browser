# 006 — Space isolation via data stores; partitioning in memory

**Status:** accepted (M2)

Two decisions, both about where a Space's boundary actually lives.

## Isolation is WebKit's, not ours

Each Space owns a `dataStoreID` and maps to
`WKWebsiteDataStore(forIdentifier:)`. Cookies, localStorage, and cache are then
separated by WebKit itself rather than by anything we filter — which is what
makes two accounts on one site work at the same time, with no profile switching
(3.3). A private Space uses `.nonPersistent()` instead.

The property is tested against real data stores, not fakes
(`DataStoreIsolationTests`), because a fake proving isolation would prove
nothing about the thing we depend on. Stores are created lazily and cached by
Space id; deleting a Space calls `removeDataStore(forIdentifier:)` behind a
confirmation, since it is irreversible.

The consequence worth remembering: **a web view belongs to the Space it was
created in.** `surface(for:)` resolves the Space from the *tab*, never from the
current selection, and moving a tab between Spaces tears its view down first.
Reusing the view across a move would carry the old Space's cookies with it,
silently defeating the whole feature.

## Tabs are partitioned in memory, not by query

`loadAll()` still returns every tab across every Space, and the store filters to
`visibleTabs`. A per-Space query would be the obvious alternative and is the
wrong call here: 6.1 budgets 100 ms from Space switch to first painted frame,
and the tab set is small enough that going to disk on every switch spends that
budget for nothing. Switching is an in-memory filter plus a selection lookup.

For the same reason web views are **not** evicted when leaving a Space. The LRU
cap is what bounds them. Evicting on switch would make returning to a Space a
reload, which is precisely the latency the budget forbids.

Tab order is per-Space, so adding a tab in one Space cannot renumber another's.

## Orphans

A tab whose Space no longer exists is re-homed into the first Space at restore,
not dropped — an invisible tab reads to the user as data loss. The v2 migration
does the same thing at the schema level: it generates a default Space and adopts
every existing v1 tab into it, deleting nothing (7.2).
