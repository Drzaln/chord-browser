# 003 — No `Space` type in M1

**Status:** accepted (M1), superseded by M2 when Spaces land

BROWSER_SPEC 3.2 shows `Tab.spaceID` in the core model, but M1's scope (8) is a
flat tab list and 11 forbids scaffolding future milestones. Building a `Space`
type now would mean either a fake default Space threaded through every
signature, or a nullable field that means nothing — both are the kind of
speculative abstraction that is harder to remove than to add.

So M1 has no `Space`. `Tab` carries no `spaceID`, the schema has no space
column, and `TabRepository.loadAll()` returns the single flat list rather than
the spec's `load(spaceID:)`.

What M1 did do is shape the two places that will have to grow so the change is
additive rather than structural. The schema is versioned from v1, so M2 adds a
`spaceID` column in a `v2_add_spaces` migration alongside its own fixture test —
no table rebuild. And `WebViewPool` is keyed by pane, not by any global
assumption, so per-Space process and data-store scoping becomes a parameter on
view creation rather than a rewrite of the eviction logic.

`WKWebsiteDataStore(forIdentifier:)` — the actual point of Spaces — is untouched
in M1. The engine uses `.default()`.
