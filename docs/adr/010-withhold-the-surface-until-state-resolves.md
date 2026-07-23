# 010 — Withhold a pane's surface until its interactionState has been read

**Status:** accepted (M4, 2026-07-23)

## Context

`interactionState` blobs are large, so BROWSER_SPEC 6.5 requires them stored
out-of-line and loaded on demand. A restored `Pane` therefore arrives from the
database with `interactionState == nil`, and the blob has to be fetched at some
point before the pane's web view is built — because seeding state into a web
view that has already started loading throws that load away, and fights the user
for the scroll position if they have touched it.

The awkward part is that `TabStore.surface(for:)` is synchronous. It is called
from SwiftUI's `body`, and the read is asynchronous — GRDB on a background
queue. So the two cannot simply be sequenced.

Options considered:

1. Prefetch every blob at launch. Violates the "load on demand" requirement and
   inflates launch memory with state for tabs that may never be opened.
2. Build the view immediately, seed state when the blob arrives. Races: the view
   has already begun loading the bare URL, and the result depends on which wins.
3. Make `select` async and await the blob before switching. Turns every tab
   switch into a disk round trip, including the overwhelmingly common case of a
   tab that is already live.

## Decision

`surface(for:)` returns nil while a pane's blob is still being read.
`TabStore.stateResolution` tracks each pane as `.pending` or `.resolved`, and it
is an observed property — flipping a pane to `.resolved` is what re-renders the
content view and lets the surface through on the next pass.

The read is kicked off from `select` and from `restore`, never from `body`, so
requesting a surface stays free of side effects.

Panes are marked `.resolved` even when nothing was stored. Without that, a pane
with no saved state would be asked for on every render and never draw at all.
Brand-new tabs are marked resolved at creation, since there is definitionally
nothing on disk for them.

## Consequences

- The content view renders its card background and no web content for one frame
  after a restored tab is first selected. In exchange, a restored pane always
  comes back from state rather than reloading.
- `WebContentCard` already handled a nil surface, so no UI change was needed.
- Tests must wait for resolution before asserting on a surface. This changed one
  pre-existing test, which now polls rather than requesting the surface once.
- Restore stays lazy, which is the property this must not break: N saved tabs
  still create zero web views, and at most the selected tab's blob is read.
