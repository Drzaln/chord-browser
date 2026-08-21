# 020 — Arc-style split close and pane-level Cmd+Shift+T undo

**Status:** accepted (post-M7, shipped 2026-08-21)

## Context

Closing a split tab was all-or-nothing: `closeTab` (Cmd+W, the sidebar close
button, swipe-to-close) removed the whole tab and every pane in it. To close one
side of a split you had to know the separate `Cmd+Shift+Option+D` "Close Pane"
command, and there was no way to undo a pane close — `Cmd+Shift+T` only restored
whole tabs.

Arc's model is finer-grained: a tab is the unit of "close", a **pane** is the
unit of "swipe away", and closing either is undoable. The whole-tab close also
had a silent RAM cost — every closed tab's `interactionState` blob stayed parked
in `WebKitEngine.interactionStates` for the life of the process, and tearing a
view down never released its media pipeline.

## Decision

**Make closing split-aware and undoable.**

- `closeTab` on a tab with more than one pane closes only the **focused pane**
  (`closePane`), leaving the rest — matching Arc. The whole-tab close was
  extracted as `closeTabRemovingEveryPane`; drag-to-split still uses it for its
  source tab, because a source is *moved* into the target and must go entirely
  even if it was itself a split.
- `paneRequestedSwipeClose` closes a pane of a split; a single-pane tab still
  closes as a tab.
- `recentlyClosed` became a unified stack of `RecentlyClosed` (`.tab` or
  `.pane`). Closing a pane records the pane, its tab, and its position;
  `Cmd+Shift+T` re-inserts it at that position and re-focuses it. Private panes
  are never recorded (the store-wide rule whole private tabs already had).

## Trap found by the real engine

The reopened pane initially came back **blank** (`about:blank`). Cause:
`closePane` snapshotted the pane from the model **after** `engine.evict`, and
eviction's `tearDown()` navigates the view to `about:blank` — whose KVO snapshot
overwrote the model pane's URL before the reopen record was built. Fix: capture
the model pane **before** eviction. Only a real-engine E2E test
(`reopenClosedPaneReloadsURL`) surfaced it; the store-level tests passed because
the fake engine never navigates.

## Consequences

- **Cmd+W on a split leaves the tab alive** — a deliberate behaviour change from
  "close everything". The last pane still closes the tab.
- `Cmd+Shift+T` restores a closed pane at its previous position, LIFO across
  mixed pane/tab closes. A pane whose tab no longer exists (Space deleted) is
  dropped silently.
- Pane reopen reloads the URL rather than restoring scroll — the interaction
  blob is pruned on close, the same trade tab reopen already made.
- Alongside: `engine.forget(paneID:)` clears a truly-closed pane's cached state
  (interaction state, last-known URL, mute, sleep timer), `interactionStates` is
  LRU-capped at 20, and `LiveWebView.tearDown()` calls
  `closeAllMediaPresentations()` so a closed media tab releases its buffers.