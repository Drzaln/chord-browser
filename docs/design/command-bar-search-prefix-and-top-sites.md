# Design proposal — command bar: `?` search prefix + top sites on empty query

**Status: proposed (2026-08-28).** Two QoL slices for the command bar, ranked
first by daily value in the QoL list: the `?` force-search prefix and
most-visited sites on an empty bar. This document is the **design source of
truth**; the tickets carry tracking + acceptance criteria:

- **`?` prefix** — bead `webkit-arc-like-browser-dis`
- **Top sites on empty query** — bead `webkit-arc-like-browser-c68`

An agent implementing either slice should read this document and its ticket
together. Anything ambiguous resolves here, not in the ticket.

## Why

Two everyday frictions, both in the bar's fallback path (`CommandBarRanking` +
`URLInput`):

1. **The URL-vs-search guess misfires the wrong way.** `URLInput.resolve`
   (`ChordCore/URLInput.swift:13`) treats any single dot-containing token as a
   host (`looksLikeHost`, `URLInput.swift:55`), so `golang.org` navigates even
   when the user meant "search golang.org". There is no way to say "search
   this" except retyping as prose (`golang org`). A typed `?` prefix removes the
   whole misfire class for a trivial branch.
2. **An empty bar is a blank start.** An empty query shows only open tabs —
   `history`/`archived`/`commands`/`fallback` all guard `query.isEmpty`
   (`CommandBarRanking.swift:167, 187, 206, 222`). Every browser worth the name
   shows the frequent sites the moment the bar opens. The data is already in
   memory: `TabStore+CommandBar.swift:11` loads the active Space's history into
   `cachedHistory` (500 rows) when the bar opens, and `suggestions(for:)`
   (`TabStore+CommandBar.swift:46`) hands it to the ranker. Zero extra disk or
   network cost.

## Current behaviour (the ground truth an agent must not break)

When the user types into the bar, `CommandBarRanking.suggestions(for:)`
(`CommandBarRanking.swift:116`) runs these sources, sorts by `score` desc (ties
by title), caps at `resultLimit = 12`, then inserts the fallback row at index 0:

1. `openTabs` (`:146`) — fuzzy match on each tab's title + URL via
   `FuzzyMatch.bestScore`; base + `openTabBias(40)` + recency.
   `FuzzyMatch.score` returns **0 for an empty query** (`FuzzyMatch.swift:25`),
   so every open tab matches on an empty query at base 0.
2. `history` (`:165`) — **guards `query.isEmpty`**; base + `historyBias(0)` +
   `min(visitCount * 3, visitCountMax(15))` + recency.
3. `archived` (`:186`) — **guards empty**; base + `archivedBias(-10)` + recency.
4. `commands` (`:205`) — **guards empty**; base + `commandBias(5)`.
5. `fallback` (`:221`) — **guards empty**; `URLInput.resolve(query,
   searchTemplate:)` → `.navigate(url:)` for a host-like token, `.search(query:
   url:)` otherwise; score `Int.min`, inserted at index 0 so Return always acts
   on it.

Recency: exponential decay, `recencyMax(30)` over `recencyHalfLife` (3 days),
`CommandBarRanking.swift:238`.

## Change 1 — `?` prefix forces search

### Behaviour (edge-case table, normative)

| Typed input | Result |
|---|---|
| `?golang.org` | `.search` "golang.org" — **never navigates** |
| `? golang.org` (space after `?`) | `.search` "golang.org" |
| `?localhost` | `.search` "localhost" — never hits the `localhost` navigate rule |
| `?` alone | falls through to today's path → searches "?" (harmless) |
| `??` | forced query `"?"` — searched literally |
| `?  ` (only `?` + whitespace) | falls through to today's path (forced query empty → nil) |
| `example.com` (no `?`) | `.navigate`, exactly as today |
| any URL with a scheme (`https://x`) | `.navigate`, exactly as today |

Rationale for the fall-through cases: a forced search with an empty query is
nonsense, so `?` alone behaves like today. There is no real-URL conflict — a URL
scheme cannot begin with `?`, and `URL(string: "?x")` has a nil scheme — so
nothing that resolves today changes.

### `ChordCore/URLInput.swift` — one new helper, nothing else

```swift
/// "?golang.org" or "? golang.org" -> "golang.org"; nil when the text does
/// not begin with "?" (after trimming) or is nothing but the "?".
public static func forcedSearchQuery(_ raw: String) -> String? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.hasPrefix("?") else { return nil }
    let rest = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    return rest.isEmpty ? nil : rest
}
```

Do **not** touch `resolve`, `isSearch`, or `looksLikeHost` for this change. The
ranker checks forced-search *before* calling `resolve`, so the navigate branch
is never entered for a `?` input.

### `ChordCore/CommandBarRanking.swift` — first branch in `fallback`

Replace the start of `fallback(query:input:)` (`:221`) so it becomes:

```swift
private static func fallback(query: String, input: CommandBarInput) -> Suggestion? {
    guard !query.isEmpty else { return nil }

    // "?golang.org" -> always a search, never a navigation.
    if let forced = URLInput.forcedSearchQuery(query) {
        return Suggestion(
            id: "search",
            kind: .search(
                query: forced,
                url: URLInput.search(for: forced, template: input.searchTemplate)
            ),
            title: "Search for “\(forced)”",
            subtitle: "Search",
            score: Int.min
        )
    }

    guard let url = URLInput.resolve(query, searchTemplate: input.searchTemplate)
    else { return nil }
    let isSearch = URLInput.isSearch(query)
    return Suggestion(
        id: isSearch ? "search" : "navigate",
        kind: isSearch ? .search(query: query, url: url) : .navigate(url: url),
        title: isSearch ? "Search for “\(query)”" : query,
        subtitle: isSearch ? "Search" : url.absoluteString,
        score: Int.min
    )
}
```

The `?` never leaks into the row title: the row says `Search for "golang.org"`,
not `Search for "?golang.org"`.

## Change 2 — top sites on empty query

### Behaviour (normative)

- Empty query → bar shows open tabs (as today) **plus** up to 6 top-history
  rows below them.
- Non-empty query → no top-sites source; the regular `history` source is
  unchanged.
- Empty query + empty history → no top-sites rows (today's look).
- Private window → no top-sites rows, for free: the store passes `history: []`
  for a private window (`TabStore+CommandBar.swift:60`).
- Row kind is `.history(url:)` (same as history rows) so `activate()` and the
  row UI (`CommandBarRow`) are untouched — Return says "Go to Page".
- Rows may outrank low-recent open tabs: top-sites max score is
  `15 + 30 = 45`, open tabs start at `40 + recency`. This is intended; the
  existing sort decides. Do not add a bias to force order.

### Scoring (exactly the history formula)

Reuse `CommandBarRanking.swift:174` with `base = 0`:

```
score = 0 + min(entry.visitCount * 3, Weight.visitCountMax)
      + recencyBonus(from: entry.lastVisitedAt, now: input.now)
```

Factor a shared row-builder so `history` and `topSites` cannot drift:

```swift
private static func historySuggestion(
    for entry: HistoryEntry, base: Int, input: CommandBarInput
) -> Suggestion {
    let frequency = min(entry.visitCount * 3, Weight.visitCountMax)
    return Suggestion(
        id: "history-\(entry.id.uuidString)",
        kind: .history(url: entry.url),
        title: entry.displayTitle,
        subtitle: entry.url.absoluteString,
        score: base + Weight.historyBias + frequency
            + recencyBonus(from: entry.lastVisitedAt, now: input.now)
    )
}
```

`history(query:input:)` (`:165`) then keeps its fuzzy guard and calls
`historySuggestion(for:base:input:)` with `base =` the fuzzy match; `topSites`
calls it with `base = 0`.

### New source

```swift
/// Most-visited history, shown only when nothing is typed (QoL #2). The
/// store already cached the active Space's history, so this is pure ranking.
private static func topSites(input: CommandBarInput, limit: Int = 6) -> [Suggestion] {
    guard input.query.isEmpty else { return [] }
    return input.history
        .sorted { lhs, rhs in
            // Exact same comparison the sort in `suggestions` would do, so a
            // full sort here + prefix is equivalent to ranking all rows.
            let l = historySuggestion(for: lhs, base: 0, input: input)
            let r = historySuggestion(for: rhs, base: 0, input: input)
            return l.score == r.score ? l.title < r.title : l.score > r.score
        }
        .prefix(limit)
        .map { historySuggestion(for: $0, base: 0, input: input) }
}
```

(If the double-scoring feels wasteful: history is ≤ 500 rows, this runs once per
keystroke against an in-memory cache, and the bar is already budgeted to stay
free at 50 ms open-to-input (`TabStore+CommandBar.swift:8`). Correctness first.)

### Wire into `suggestions`

`CommandBarRanking.suggestions` (`:116`) appends the source with the others:

```swift
results += openTabs(query: query, input: input)
results += topSites(input: input)
results += history(query: query, input: input)
// ...
```

No other source changes. The global sort + `resultLimit` + fallback-insert
handle ordering and the cap as today.

## Tests (run: `swift test --package-path Packages`)

### `ChordCoreTests/URLInputTests.swift` — `forcedSearchQuery` table

| Input | Expected |
|---|---|
| `?golang.org` | `golang.org` |
| `? golang.org` | `golang.org` |
| ` ?x ` | `x` |
| `?  ` | `nil` |
| `?` | `nil` |
| `??` | `?` |
| `example.com` | `nil` |
| `https://x` | `nil` |

### `ChordCoreTests/RankingTests.swift`

- `"?" forces search, never navigate`: query `?golang.org` → first row is
  `.search(query: "golang.org", ...)`; title `Search for "golang.org"` (no `?`);
  url equals `URLInput.search(for: "golang.org", template:)`; and no row is
  `.navigate`.
- `"?" beats the localhost navigate rule`: `?localhost` → `.search`, never
  `.navigate`.
- `plain host still navigates`: `example.com` (no `?`) → first row `.navigate`.
- `empty query shows top sites`: empty query + history of 3+ entries with
  distinct `visitCount` → top-sites rows present, descending by visit count,
  count ≤ 6, each `.history` with subtitle = URL.
- `empty query + empty history shows none`: no top-sites rows.
- `typing hides top sites`: any non-empty query → no top-sites rows.

### Existing tests that must stay green

- `ChordStoreTests/PreferencesTests.swift:60` (`"swift concurrency"` → search
  suggestion).
- `ChordStoreTests/CommandBarDestinationTests.swift` (activation semantics —
  `.history` rows unchanged).

## Manual verification (app, Developer-mode not required)

1. Open the command bar, type `?golang.org` → top row reads
   `Search for "golang.org"`, Return searches.
2. Type `?localhost` → searches "localhost", no navigation attempt.
3. Type `golang.org` (no `?`) → still a navigate row.
4. Open the bar with the field empty → frequent sites appear under open tabs;
   in a private window they do not.

## Out of scope (separate tickets, do not implement here)

- Inline domain autocomplete (typed prefix → known domain) — bead
  `webkit-arc-like-browser-354`. Needs its own design: completion text in
  `CommandBarView`, arrow-key semantics, dedupe against the navigate row.
- URL heuristic polish (TLD table, `www` handling, intranet hosts) — bead
  `webkit-arc-like-browser-4ey`.
- `@site` site search — bead `webkit-arc-like-browser-kyx`.
- `!` bangs / mid-typing engine switch — bead `webkit-arc-like-browser-big`.

## Decided

1. `?` is the prefix: one keystroke, no modifier, matches Chrome's "I want to
   search" intent.
2. Top sites default to 6 rows: useful under the open tabs, small enough not to
   bury the fallback the moment typing starts.
3. Both land in `ChordCore` as pure, unit-tested code; no UI, store, or engine
   changes. Private-window correctness falls out of the existing
   `history: []` injection.