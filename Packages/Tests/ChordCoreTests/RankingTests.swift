import ChordCore
import ChordTestSupport
import Foundation
import Testing

@Suite("Fuzzy matching")
struct FuzzyMatchTests {

    @Test("An exact match outranks a prefix, which outranks a subsequence")
    func orderingOfMatchQuality() throws {
        let exact = try #require(FuzzyMatch.score(query: "github", candidate: "github"))
        let prefix = try #require(FuzzyMatch.score(query: "github", candidate: "github.com"))
        let scattered = try #require(
            FuzzyMatch.score(query: "github", candidate: "go home in the hub")
        )

        #expect(exact > prefix)
        #expect(prefix > scattered)
    }

    @Test("A non-subsequence does not match at all")
    func nonMatch() {
        #expect(FuzzyMatch.score(query: "zzz", candidate: "github.com") == nil)
        #expect(FuzzyMatch.score(query: "githubb", candidate: "github") == nil)
    }

    @Test("Matching is case-insensitive")
    func caseInsensitive() {
        #expect(FuzzyMatch.score(query: "GITHUB", candidate: "github.com") != nil)
        #expect(FuzzyMatch.score(query: "github", candidate: "GitHub.com") != nil)
    }

    @Test("An empty query matches everything neutrally")
    func emptyQuery() {
        #expect(FuzzyMatch.score(query: "", candidate: "anything") == 0)
    }

    @Test("Word starts score better than mid-word matches")
    func wordStartsWin() throws {
        let atBoundary = try #require(
            FuzzyMatch.score(query: "ny", candidate: "new york")
        )
        let midWord = try #require(
            FuzzyMatch.score(query: "ny", candidate: "many")
        )
        #expect(atBoundary > midWord)
    }

    @Test("Shorter candidates win when the match is otherwise equal")
    func shorterWins() throws {
        let short = try #require(FuzzyMatch.score(query: "git", candidate: "git.io"))
        let long = try #require(
            FuzzyMatch.score(query: "git", candidate: "git.io/a/very/long/path/indeed/x")
        )
        #expect(short > long)
    }

    @Test("bestScore takes the better of title and URL")
    func bestOfSeveralFields() throws {
        let best = try #require(
            FuzzyMatch.bestScore(
                query: "github", candidates: ["Unrelated Title", "https://github.com"]
            )
        )
        let titleOnly = FuzzyMatch.score(query: "github", candidate: "Unrelated Title")
        #expect(titleOnly == nil)
        #expect(best > 0)
    }
}

@Suite("Command bar ranking")
struct CommandBarRankingTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func input(
        query: String,
        tabs: [Tab] = [],
        history: [HistoryEntry] = [],
        archived: [ArchivedTab] = []
    ) -> CommandBarInput {
        CommandBarInput(
            query: query,
            tabs: tabs,
            spaceNames: [TabBuilder.defaultSpaceID: "Personal"],
            history: history,
            archived: archived,
            now: now
        )
    }

    @Test("An open tab outranks history at equal text score")
    func openTabsOutrankHistory() throws {
        let tab = TabBuilder().url("https://github.com").title("GitHub").build()
        let entry = HistoryEntry(
            url: URL(string: "https://github.com")!, title: "GitHub", lastVisitedAt: now
        )

        let results = CommandBarRanking.suggestions(
            for: input(query: "github", tabs: [tab], history: [entry])
        )

        // 4.4 states this explicitly: open tabs outrank history at equal score.
        // The search fallback sits above both, so compare the two relative to
        // each other rather than expecting the tab at the very top.
        let kinds = results.map(\.kind)
        let tabIndex = try #require(kinds.firstIndex { if case .openTab = $0 { true } else { false } })
        let historyIndex = try #require(kinds.firstIndex { if case .history = $0 { true } else { false } })
        #expect(tabIndex < historyIndex)
    }

    @Test("Recent items outrank stale ones")
    func recencyWeighting() throws {
        let recent = HistoryEntry(
            url: URL(string: "https://example.com/recent")!,
            title: "Example Recent",
            lastVisitedAt: now.addingTimeInterval(-60)
        )
        let stale = HistoryEntry(
            url: URL(string: "https://example.com/stale")!,
            title: "Example Stale",
            lastVisitedAt: now.addingTimeInterval(-90 * 24 * 60 * 60)
        )

        let results = CommandBarRanking.suggestions(
            for: input(query: "example", history: [stale, recent])
        )
        let titles = results.map(\.title)
        let recentIndex = try #require(titles.firstIndex(of: "Example Recent"))
        let staleIndex = try #require(titles.firstIndex(of: "Example Stale"))
        #expect(recentIndex < staleIndex)
    }

    @Test("Tabs from every Space are searchable, not just the active one")
    func searchesAllSpaces() {
        let other = UUID()
        let tabs = [
            TabBuilder().url("https://a.example").title("Alpha").build(),
            TabBuilder().url("https://b.example").title("Alpha Two").space(other).build(),
        ]

        let results = CommandBarRanking.suggestions(for: input(query: "alpha", tabs: tabs))
        #expect(results.filter { if case .openTab = $0.kind { true } else { false } }.count == 2)
    }

    @Test("Archived tabs are searchable from the bar")
    func archivedAreSearchable() throws {
        let archived = ArchivedTab(
            url: URL(string: "https://closed.example")!,
            title: "Closed Thing",
            spaceID: TabBuilder.defaultSpaceID,
            archivedAt: now
        )

        let results = CommandBarRanking.suggestions(
            for: input(query: "closed", archived: [archived])
        )
        #expect(results.contains { if case .archived = $0.kind { true } else { false } })
    }

    @Test("Commands are reachable by name")
    func commandsMatch() {
        let results = CommandBarRanking.suggestions(for: input(query: "new space"))
        #expect(results.contains { $0.kind == .command(.newSpace) })
    }

    @Test("A URL-like query always offers navigation")
    func urlFallback() throws {
        let results = CommandBarRanking.suggestions(for: input(query: "example.com"))
        let navigate = try #require(
            results.first { if case .navigate = $0.kind { true } else { false } }
        )
        guard case .navigate(let url) = navigate.kind else { return }
        #expect(url.absoluteString == "https://example.com")
    }

    @Test("A non-URL query always offers a search")
    func searchFallback() {
        let results = CommandBarRanking.suggestions(for: input(query: "how to fix a bike"))
        #expect(results.contains { if case .search = $0.kind { true } else { false } })
    }

    @Test("The site registry resolves aliases case-insensitively")
    func siteRegistryAliases() {
        #expect(SiteRegistry.entry(forAlias: "gh")?.name == "GitHub")
        #expect(SiteRegistry.entry(forAlias: "GH")?.name == "GitHub")
        #expect(SiteRegistry.entry(forAlias: "w")?.name == "Wikipedia")
        #expect(SiteRegistry.entry(forAlias: "nope") == nil)
    }

    @Test("\"@alias query\" opens the registered site's search URL", arguments: [
        ("@gh swift", "swift", "https://github.com/search?q=swift"),
        ("@so stack overflow", "stack overflow", "https://stackoverflow.com/search?q=stack%20overflow"),
    ])
    func siteSearchDispatch(typed: String, expectedQuery: String, expectedURL: String) throws {
        let results = CommandBarRanking.suggestions(for: input(query: typed))
        let first = try #require(results.first)
        guard case .search(let query, let url) = first.kind else {
            Issue.record("expected a search row, got \(first.kind)")
            return
        }
        #expect(query == expectedQuery)
        #expect(url.absoluteString == expectedURL)
    }

    @Test("An unknown '@alias' falls back to a normal search")
    func unknownAliasFallsBack() throws {
        let results = CommandBarRanking.suggestions(for: input(query: "@zzz hello"))
        let first = try #require(results.first)
        guard case .search(_, let url) = first.kind else {
            Issue.record("expected a search row, got \(first.kind)")
            return
        }
        #expect(url.absoluteString.hasPrefix("https://www.google.com/search?q="))
    }

    @Test("\"!alias query\" forces the alias's search engine", arguments: [
        ("!ddg swift", "https://duckduckgo.com/?q=swift"),
        ("!g swift", "https://www.google.com/search?q=swift"),
        ("!w swift", "https://en.wikipedia.org/w/index.php?search=swift"),
    ])
    func bangDispatch(typed: String, expectedURL: String) throws {
        let results = CommandBarRanking.suggestions(for: input(query: typed))
        let first = try #require(results.first)
        guard case .search(_, let url) = first.kind else {
            Issue.record("expected a search row, got \(first.kind)")
            return
        }
        #expect(url.absoluteString == expectedURL)
    }

    @Test("'@' and '!' resolve the same alias consistently")
    func bangAndSiteShareTheRegistry() throws {
        let atResults = CommandBarRanking.suggestions(for: input(query: "@gh swift"))
        let bangResults = CommandBarRanking.suggestions(for: input(query: "!gh swift"))
        guard case .search(_, let atURL) = try #require(atResults.first).kind else {
            Issue.record("expected a search row from '@gh'")
            return
        }
        guard case .search(_, let bangURL) = try #require(bangResults.first).kind else {
            Issue.record("expected a search row from '!gh'")
            return
        }
        #expect(atURL == bangURL)
    }

    @Test("An unknown '!alias' falls back to a normal search")
    func unknownBangFallsBack() throws {
        let results = CommandBarRanking.suggestions(for: input(query: "!zzz hello"))
        let first = try #require(results.first)
        guard case .search(_, let url) = first.kind else {
            Issue.record("expected a search row, got \(first.kind)")
            return
        }
        #expect(url.absoluteString.hasPrefix("https://www.google.com/search?q="))
    }

    @Test("\"?\" forces search, never navigate")
    func forcedSearchPrefix() throws {
        let results = CommandBarRanking.suggestions(for: input(query: "?golang.org"))
        let first = try #require(results.first)
        guard case .search(let query, let url) = first.kind else {
            Issue.record("expected a search row, got \(first.kind)")
            return
        }
        #expect(query == "golang.org")
        #expect(first.title == "Search for “golang.org”", "the '?' must not leak into the title")
        #expect(url == URLInput.search(for: "golang.org"))
        #expect(!results.contains { if case .navigate = $0.kind { true } else { false } })
    }

    @Test("\"?\" beats the localhost navigate rule")
    func forcedSearchBeatsLocalhost() throws {
        let results = CommandBarRanking.suggestions(for: input(query: "?localhost"))
        let first = try #require(results.first)
        guard case .search = first.kind else {
            Issue.record("expected a search row, got \(first.kind)")
            return
        }
        #expect(!results.contains { if case .navigate = $0.kind { true } else { false } })
    }

    @Test("A plain host still navigates")
    func plainHostStillNavigates() throws {
        let results = CommandBarRanking.suggestions(for: input(query: "example.com"))
        let first = try #require(results.first)
        guard case .navigate(let url) = first.kind else {
            Issue.record("expected a navigate row, got \(first.kind)")
            return
        }
        #expect(url.absoluteString == "https://example.com")
    }

    @Test("An empty query with no history stays quiet")
    func emptyQueryIsQuiet() {
        let results = CommandBarRanking.suggestions(for: input(query: "", history: []))
        #expect(results.isEmpty)
    }

    @Test("An empty query shows top sites below open tabs, bounded at 6")
    func emptyQueryShowsTopSites() throws {
        let history = [
            HistoryEntry(
                url: URL(string: "https://one.example")!, title: "One",
                lastVisitedAt: now, visitCount: 5
            ),
            HistoryEntry(
                url: URL(string: "https://two.example")!, title: "Two",
                lastVisitedAt: now, visitCount: 4
            ),
            HistoryEntry(
                url: URL(string: "https://three.example")!, title: "Three",
                lastVisitedAt: now, visitCount: 2
            ),
        ]

        let results = CommandBarRanking.suggestions(for: input(query: "", history: history))
        let topSites = results.filter { if case .history = $0.kind { true } else { false } }
        #expect(topSites.count == 3)
        #expect(topSites.map(\.title) == ["One", "Two", "Three"], "ordered by visit count")
        #expect(topSites.allSatisfy { if case .history = $0.kind { true } else { false } })
    }

    @Test("An empty query caps top sites at 6")
    func emptyQueryCapsTopSites() {
        let history = (0..<12).map {
            HistoryEntry(
                url: URL(string: "https://example.com/\($0)")!,
                title: "Site \($0)", lastVisitedAt: now, visitCount: 100 - $0
            )
        }
        let results = CommandBarRanking.suggestions(for: input(query: "", history: history))
        let topSites = results.filter { if case .history = $0.kind { true } else { false } }
        #expect(topSites.count <= 6)
    }

    @Test("Typing hides top sites")
    func typingHidesTopSites() {
        let entry = HistoryEntry(
            url: URL(string: "https://example.com")!, title: "Example", lastVisitedAt: now
        )
        // A query that matches no history row: any .history row present now
        // would have to come from the empty-query-only topSites source.
        let results = CommandBarRanking.suggestions(
            for: input(query: "zzz", history: [entry])
        )
        let topSites = results.filter { if case .history = $0.kind { true } else { false } }
        #expect(topSites.isEmpty)
    }

    @Test("Results are capped so the panel cannot grow without bound")
    func resultsCapped() {
        let history = (0..<80).map {
            HistoryEntry(
                url: URL(string: "https://example.com/\($0)")!,
                title: "Example \($0)",
                lastVisitedAt: now
            )
        }
        let results = CommandBarRanking.suggestions(for: input(query: "example", history: history))
        #expect(results.count <= CommandBarRanking.resultLimit + 1)  // +1 for the fallback
    }

    @Test("Frequently visited pages edge ahead of one-offs")
    func visitCountMatters() throws {
        let frequent = HistoryEntry(
            url: URL(string: "https://example.com/a")!,
            title: "Example A",
            lastVisitedAt: now,
            visitCount: 20
        )
        let once = HistoryEntry(
            url: URL(string: "https://example.com/b")!,
            title: "Example B",
            lastVisitedAt: now,
            visitCount: 1
        )

        let results = CommandBarRanking.suggestions(
            for: input(query: "example", history: [once, frequent])
        )
        let titles = results.map(\.title)
        #expect(
            try #require(titles.firstIndex(of: "Example A"))
                < #require(titles.firstIndex(of: "Example B"))
        )
    }

    @Test("A typed address outranks an open tab that merely fuzzy-matches it")
    func typedAddressWinsTopSlot() throws {
        // The reported bug: typing a complete address highlighted an open tab in
        // another Space, so Return switched Space instead of navigating.
        let tab = TabBuilder()
            .url("https://github.com/groue/GRDB.swift")
            .title("GRDB")
            .build()

        let results = CommandBarRanking.suggestions(
            for: input(query: "github.com", tabs: [tab])
        )

        let first = try #require(results.first)
        guard case .navigate(let url) = first.kind else {
            Issue.record("expected the typed address first, got \(first.kind)")
            return
        }
        #expect(url.absoluteString == "https://github.com")
    }

    @Test("A bare host counts as a typed address")
    func bareHostWinsTopSlot() throws {
        let tab = TabBuilder().url("https://example.com/deep/page").title("Example").build()

        let results = CommandBarRanking.suggestions(
            for: input(query: "example.com", tabs: [tab])
        )

        guard case .navigate = try #require(results.first).kind else {
            Issue.record("expected a navigate suggestion first")
            return
        }
    }

    @Test("A typed domain prefix completes from history with the suffix highlighted")
    func domainPrefixCompletesFromHistory() throws {
        let entry = HistoryEntry(
            url: URL(string: "https://youtube.com")!, title: "YouTube", lastVisitedAt: now
        )

        let results = CommandBarRanking.suggestions(for: input(query: "you", history: [entry]))
        let autocomplete = try #require(
            results.first { $0.completion != nil }
        )
        #expect(autocomplete.title == "youtube.com")
        #expect(autocomplete.completion == "tube.com")
        guard case .navigate(let url) = autocomplete.kind else {
            Issue.record("expected the completion to navigate, got \(autocomplete.kind)")
            return
        }
        #expect(url.absoluteString == "https://youtube.com")
    }

    @Test("A typed domain prefix completes from open-tab domains")
    func domainPrefixCompletesFromOpenTabs() throws {
        let tab = TabBuilder().url("https://stackoverflow.com").title("SO").build()

        let results = CommandBarRanking.suggestions(for: input(query: "stack", tabs: [tab]))
        let autocomplete = try #require(results.first { $0.completion != nil })
        #expect(autocomplete.title == "stackoverflow.com")
        #expect(autocomplete.completion == "overflow.com")
    }

    @Test("A fully-typed domain does not autocomplete (navigate owns it)")
    func fullyTypedDomainDoesNotComplete() {
        let entry = HistoryEntry(
            url: URL(string: "https://youtube.com")!, title: "YouTube", lastVisitedAt: now
        )
        let results = CommandBarRanking.suggestions(
            for: input(query: "youtube.com", history: [entry])
        )
        #expect(results.allSatisfy { $0.completion == nil })
        #expect(results.contains { if case .navigate = $0.kind { true } else { false } })
    }

    @Test("Typing diverges from the suggestion clears it")
    func divergenceClearsCompletion() {
        let entry = HistoryEntry(
            url: URL(string: "https://youtube.com")!, title: "YouTube", lastVisitedAt: now
        )
        let results = CommandBarRanking.suggestions(
            for: input(query: "youx", history: [entry])
        )
        #expect(results.allSatisfy { $0.completion == nil })
    }

    @Test("A query with a space or slash never completes")
    func spaceOrSlashNeverCompletes() {
        let entry = HistoryEntry(
            url: URL(string: "https://youtube.com")!, title: "YouTube", lastVisitedAt: now
        )
        #expect(
            CommandBarRanking.suggestions(for: input(query: "you tube", history: [entry]))
                .allSatisfy { $0.completion == nil }
        )
        #expect(
            CommandBarRanking.suggestions(for: input(query: "you/", history: [entry]))
                .allSatisfy { $0.completion == nil }
        )
    }

    @Test("A search query keeps the top slot")
    func searchQueryKeepsTopSlot() throws {
        // Like a typed address, the search fallback jumps the queue so Return
        // acts on it without scrolling the list.
        let tab = TabBuilder().url("https://github.com").title("GitHub").build()

        let results = CommandBarRanking.suggestions(
            for: input(query: "github", tabs: [tab])
        )

        guard case .search = try #require(results.first).kind else {
            Issue.record("expected the search fallback first, got \(String(describing: results.first?.kind))")
            return
        }
    }

    @Test("Every row states what Return will do to it")
    func rowsCarryAnActionLabel() throws {
        let tab = TabBuilder().url("https://github.com").title("GitHub").build()
        let results = CommandBarRanking.suggestions(
            for: input(query: "github", tabs: [tab])
        )

        // The cross-Space jump has to be visible before it happens, not after.
        let openTab = try #require(results.first { if case .openTab = $0.kind { true } else { false } })
        #expect(openTab.actionLabel(for: .newTab) == "Switch to Tab")

        let search = try #require(results.first { if case .search = $0.kind { true } else { false } })
        #expect(search.actionLabel(for: .newTab) == "Search")

        // Opened to fill a split, the same rows must say so instead. An open
        // tab is *moved* into the split there, not switched to.
        #expect(openTab.actionLabel(for: .newPane) == "Move to Split")
        #expect(search.actionLabel(for: .newPane) == "Search in Split")
    }
}
