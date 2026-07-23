import BrowserCore
import BrowserTestSupport
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
        let first = try #require(results.first)
        guard case .openTab = first.kind else {
            Issue.record("expected an open tab first, got \(first.kind)")
            return
        }
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

    @Test("An empty query does not dump history into the bar")
    func emptyQueryIsQuiet() {
        let entry = HistoryEntry(
            url: URL(string: "https://example.com")!, title: "Example", lastVisitedAt: now
        )
        let results = CommandBarRanking.suggestions(for: input(query: "", history: [entry]))
        #expect(results.isEmpty)
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

    @Test("A search query still sorts last, so an open tab keeps the top slot")
    func searchQueryStaysLast() throws {
        // Only a *complete* address jumps the queue. For ordinary words an open
        // tab really is the better guess, which is 4.4's rule.
        let tab = TabBuilder().url("https://github.com").title("GitHub").build()

        let results = CommandBarRanking.suggestions(
            for: input(query: "github", tabs: [tab])
        )

        guard case .openTab = try #require(results.first).kind else {
            Issue.record("expected the open tab first for a non-address query")
            return
        }
        guard case .search = try #require(results.last).kind else {
            Issue.record("expected the search fallback last")
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
        #expect(openTab.actionLabel == "Switch to Tab")

        let search = try #require(results.first { if case .search = $0.kind { true } else { false } })
        #expect(search.actionLabel == "Search")
    }
}
