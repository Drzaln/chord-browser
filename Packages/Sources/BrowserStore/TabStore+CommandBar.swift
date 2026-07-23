import BrowserCore
import Foundation

/// Command bar behaviour (4.4).
@MainActor
extension TabStore {

    /// History and archive are cached in memory and refreshed when the bar
    /// opens, so typing never touches the disk — the bar has a 50 ms
    /// open-to-input-ready budget and keystrokes must stay free (6.1).
    public func prepareCommandBar() async {
        async let history = loadHistory()
        async let archived = loadArchive()
        cachedHistory = await history
        cachedArchive = await archived
    }

    private func loadHistory() async -> [HistoryEntry] {
        do {
            return try await historyRepository?.recentHistory(limit: 500) ?? []
        } catch {
            Log.store.error("history load failed: \(String(describing: error))")
            return []
        }
    }

    private func loadArchive() async -> [ArchivedTab] {
        do {
            return try await archiveRepository?.archivedTabs() ?? []
        } catch {
            Log.store.error("archive load failed: \(String(describing: error))")
            return []
        }
    }

    /// Ranked results for what the user has typed. Pure ranking, so the
    /// interesting logic is tested without a UI (`CommandBarRanking`).
    public func suggestions(for query: String) -> [Suggestion] {
        CommandBarRanking.suggestions(
            for: CommandBarInput(
                query: query,
                // Open tabs from every Space are searchable, not just the
                // active one (4.4).
                tabs: tabs,
                spaceNames: Dictionary(
                    uniqueKeysWithValues: spaces.map { ($0.id, $0.name) }
                ),
                history: cachedHistory,
                archived: cachedArchive,
                now: clock.now
            )
        )
    }

    /// - Parameter forceNewTab: `Cmd+Enter` — open in a new tab rather than
    ///   navigating the current one (4.4).
    public func activate(_ suggestion: Suggestion, forceNewTab: Bool = false) {
        switch suggestion.kind {
        case .openTab(let tabID, let spaceID, _):
            if spaceID != activeSpaceID { selectSpace(spaceID) }
            select(tabID)

        case .history(let url), .navigate(let url):
            open(url, forceNewTab: forceNewTab)

        case .search(_, let url):
            open(url, forceNewTab: forceNewTab)

        case .archived(let tab):
            restoreArchived(tab)

        case .command(let command):
            run(command)
        }
    }

    private func open(_ url: URL, forceNewTab: Bool) {
        if forceNewTab || selectedTab == nil {
            newTab(url: url)
        } else {
            navigate(to: url)
        }
    }

    private func run(_ command: BrowserCommand) {
        switch command {
        case .newTab: newTab()
        case .closeTab: selectedTabID.map { closeTab($0) }
        case .newSpace: addSpace()
        case .reload: reload()
        }
    }

    // MARK: - History recording

    /// Called when a navigation settles. Skipped for blank and error pages so
    /// the command bar does not learn junk.
    func recordVisit(url: URL, title: String) {
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }

        let now = clock.now
        Task { [historyRepository] in
            do {
                try await historyRepository?.recordVisit(url: url, title: title, at: now)
            } catch {
                Log.store.error("history write failed: \(String(describing: error))")
            }
        }
    }
}
