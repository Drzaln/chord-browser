import Foundation

/// One row in the command bar.
public struct Suggestion: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case openTab(tabID: UUID, spaceID: UUID, spaceName: String)
        case history(url: URL)
        case archived(ArchivedTab)
        case command(BrowserCommand)
        /// Whatever the user typed, treated as a destination.
        case navigate(url: URL)
        case search(query: String, url: URL)
    }

    public let id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String
    public var score: Int

    /// What Return will actually do to this row, shown on the row itself.
    ///
    /// Without it, a fuzzy match on an open tab in another Space looks identical
    /// to a navigation, and Return silently jumps Spaces instead.
    ///
    /// Depends on the destination because the same row does different things
    /// depending on how the bar was opened: an open tab is *switched to*
    /// normally, but *moved into the split* when the bar was opened to fill a
    /// pane. §4.4 requires the row to say so before it happens, not after.
    public func actionLabel(for destination: ActivationDestination) -> String {
        switch kind {
        case .openTab: destination == .newPane ? "Move to Split" : "Switch to Tab"
        case .history, .navigate: destination == .newPane ? "Open in Split" : "Go to Page"
        case .search: destination == .newPane ? "Search in Split" : "Search"
        case .archived: "Reopen Tab"
        case .command: "Run Command"
        }
    }

    public init(id: String, kind: Kind, title: String, subtitle: String, score: Int) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.score = score
    }
}

/// Actions the bar can run directly.
public enum BrowserCommand: String, CaseIterable, Hashable, Sendable {
    case newTab
    case closeTab
    case newSpace
    case reload

    public var title: String {
        switch self {
        case .newTab: "New Tab"
        case .closeTab: "Close Tab"
        case .newSpace: "New Space"
        case .reload: "Reload Page"
        }
    }
}

/// Everything the ranker needs, gathered by the store and handed over as values.
public struct CommandBarInput: Sendable {
    public var query: String
    public var tabs: [Tab]
    public var spaceNames: [UUID: String]
    public var history: [HistoryEntry]
    public var archived: [ArchivedTab]
    public var now: Date

    public init(
        query: String,
        tabs: [Tab] = [],
        spaceNames: [UUID: String] = [:],
        history: [HistoryEntry] = [],
        archived: [ArchivedTab] = [],
        now: Date
    ) {
        self.query = query
        self.tabs = tabs
        self.spaceNames = spaceNames
        self.history = history
        self.archived = archived
        self.now = now
    }
}

/// Fuzzy scoring with recency weighting; open tabs outrank history at equal
/// score (4.4). Pure, so the whole ranking is unit-testable.
public enum CommandBarRanking {

    private enum Weight {
        /// Applied to open tabs so they win ties against history (4.4).
        static let openTabBias = 40
        static let historyBias = 0
        static let archivedBias = -10
        static let commandBias = 5
        /// Recency is worth up to this much, decaying over `recencyHalfLife`.
        static let recencyMax = 30.0
        static let recencyHalfLife: TimeInterval = 3 * 24 * 60 * 60
        /// Frequently visited pages edge ahead, but cannot swamp a better match.
        static let visitCountMax = 15
    }

    public static let resultLimit = 12

    public static func suggestions(for input: CommandBarInput) -> [Suggestion] {
        let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)

        var results: [Suggestion] = []
        results += openTabs(query: query, input: input)
        results += history(query: query, input: input)
        results += archived(query: query, input: input)
        results += commands(query: query)

        results.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.title < rhs.title : lhs.score > rhs.score
        }
        results = Array(results.prefix(resultLimit))

        // The raw URL or search fallback always stays reachable (4.4).
        //
        // A *complete* address goes first: having typed one, Return must go
        // there. It previously sorted last on `Int.min`, so any open tab that
        // fuzzy-matched the text won the highlight and Return jumped Spaces
        // instead of navigating. A search query still sorts last, because there
        // an open tab or a history hit really is the better guess.
        if let fallback = fallback(query: query) {
            switch fallback.kind {
            case .navigate: results.insert(fallback, at: 0)
            default: results.append(fallback)
            }
        }
        return results
    }

    // MARK: - Sources

    private static func openTabs(query: String, input: CommandBarInput) -> [Suggestion] {
        input.tabs.compactMap { tab in
            let pane = tab.focusedPane
            guard let base = FuzzyMatch.bestScore(
                query: query, candidates: [pane.displayTitle, pane.url.absoluteString]
            ) else { return nil }

            let spaceName = input.spaceNames[tab.spaceID] ?? ""
            return Suggestion(
                id: "tab-\(tab.id.uuidString)",
                kind: .openTab(tabID: tab.id, spaceID: tab.spaceID, spaceName: spaceName),
                title: pane.displayTitle,
                subtitle: spaceName.isEmpty ? "Open tab" : "Open tab · \(spaceName)",
                score: base + Weight.openTabBias
                    + recencyBonus(from: tab.lastAccessedAt, now: input.now)
            )
        }
    }

    private static func history(query: String, input: CommandBarInput) -> [Suggestion] {
        // An empty query should not dump the entire history into the bar.
        guard !query.isEmpty else { return [] }

        return input.history.compactMap { entry in
            guard let base = FuzzyMatch.bestScore(
                query: query, candidates: [entry.displayTitle, entry.url.absoluteString]
            ) else { return nil }

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
    }

    private static func archived(query: String, input: CommandBarInput) -> [Suggestion] {
        guard !query.isEmpty else { return [] }

        return input.archived.compactMap { tab in
            guard let base = FuzzyMatch.bestScore(
                query: query, candidates: [tab.displayTitle, tab.url.absoluteString]
            ) else { return nil }

            return Suggestion(
                id: "archived-\(tab.id.uuidString)",
                kind: .archived(tab),
                title: tab.displayTitle,
                subtitle: "Closed tab",
                score: base + Weight.archivedBias
                    + recencyBonus(from: tab.archivedAt, now: input.now)
            )
        }
    }

    private static func commands(query: String) -> [Suggestion] {
        guard !query.isEmpty else { return [] }

        return BrowserCommand.allCases.compactMap { command in
            guard let base = FuzzyMatch.score(query: query, candidate: command.title)
            else { return nil }
            return Suggestion(
                id: "command-\(command.rawValue)",
                kind: .command(command),
                title: command.title,
                subtitle: "Command",
                score: base + Weight.commandBias
            )
        }
    }

    private static func fallback(query: String) -> Suggestion? {
        guard !query.isEmpty, let url = URLInput.resolve(query) else { return nil }

        let isSearch = url.absoluteString.hasPrefix(URLInput.searchTemplate)
        return Suggestion(
            id: isSearch ? "search" : "navigate",
            kind: isSearch ? .search(query: query, url: url) : .navigate(url: url),
            title: isSearch ? "Search for “\(query)”" : query,
            subtitle: isSearch ? "Search" : url.absoluteString,
            score: Int.min
        )
    }

    /// Exponential decay, so something opened an hour ago clearly beats the same
    /// match from last month without ever overpowering the text score.
    private static func recencyBonus(from date: Date, now: Date) -> Int {
        let age = max(0, now.timeIntervalSince(date))
        let decay = pow(0.5, age / Weight.recencyHalfLife)
        return Int((Weight.recencyMax * decay).rounded())
    }
}
