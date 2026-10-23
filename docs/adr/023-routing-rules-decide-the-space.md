# 023 — Routing rules decide the Space, as a default only

**Status:** accepted

Every URL that arrives from outside the tab the user is looking at lands in one
of two hardcoded places today: a link from another app goes to Little Chord
(§4.6), and a ⌘-click or `target=_blank` goes to the focused window's active
Space. None of that can express the ordinary intent "Figma belongs in Design".
The result is dragging the same tab between Spaces several times a day.

So: a small list of rules, each *host pattern → Space*, consulted at the one
moment a URL has no destination of its own. The matcher lives above the engine
(`RouteRules.destination`, asked through `TabStore.spaceID(forRouted:kind:in:)`)
rather than in the app delegate, because there are already two callers —
`AppDelegate.application(_:open:)` and `paneRequestedBackgroundTab` — and the
only way they stay consistent is by asking one function. Anything that opens a
URL without asking it recreates exactly the drift this ADR exists to prevent.

**A rule is a default, never a hijack.** Explicit intent wins in every case:
splitting a pane, a Peek out of a pinned or favourite tab, a private window, and
a Space the user just switched to are all untouched.

The two kinds are handled differently on purpose. An **external launch** (a link
handed over by another app, the Dock, Spotlight) is what the user just asked the
system to open, so the window switches to the target Space and selects the tab —
a link parked in an invisible Space would look like nothing happened. A
**⌘-click / `target=_blank`** is a "keep this for later" gesture, so the tab is
appended to the target Space *without* switching; a toast says where it went and
clicking the toast goes there. `routesNewTabs` lets a rule exist for external
launches only, which is the common case for a work site opened from Slack.

Matching is a host suffix test, longest pattern wins, so `figma.com` covers
`www.figma.com` and `app.figma.com`; patterns must contain a dot, which rejects a
bare TLD without shipping a public-suffix list. This is the same matcher the
per-domain User-Agent and referrer maps already share (`DomainRules`). One
matcher, three consumers.

Private windows get no rules at all. A rule firing inside one either leaks a
visit into a persistent Space or gets ignored; ignoring is simpler and matches
private windows being locked to a throwaway Space.

`window.open()` popups are **not** routed. The popup's web view is created from
its opener's configuration and is therefore bound to the opener's data store
(cookies, session); moving it to another Space's data store is not a thing WebKit
allows after the fact. The tab stays where its page came from.

Storage is the `UserDefaults` preference `prefs.routeRules` — a list of choices
like the per-domain UA map, not schema-bound user data. A rule naming a deleted
Space is inert at resolution time (checked against the live Space ids), and the
Space deletion path removes it anyway so Settings never lists a dead row.

Settings → Sites is the only editor in v1; a "Open this site in…" item on the tab
context menu is a follow-up, since it needs a Space picker that does not exist
yet.

Tests: matcher table (suffix, longest-wins, TLD rejection), destination rules
(external always, new-tab switchable, deleted Space inert), store wiring (routed
background tab does not move the window; external launch does; private window
ignores rules; deleting a Space deletes its rules; persistence).
