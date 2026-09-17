import ChordCore
import Foundation

/// Command bar behaviour (4.4).
@MainActor
extension TabStore {

    /// History and archive are cached in memory and refreshed when the bar
    /// opens, so typing never touches the disk — the bar has a 50 ms
    /// open-to-input-ready budget and keystrokes must stay free (6.1).
    ///
    /// History is read for the window the bar was opened over, so the whole bar
    /// is scoped to that window's active Space (4.4).
    public func prepareCommandBar(in window: WindowState? = nil) async {
        let spaceID = (window ?? primaryWindow).activeSpaceID
        async let history = loadHistory(inSpace: spaceID)
        async let archived = loadArchive()
        cachedHistory = await history
        cachedArchive = await archived
    }

    private func loadHistory(inSpace spaceID: UUID?) async -> [HistoryEntry] {
        guard let spaceID else { return [] }
        do {
            return try await historyRepository?.recentHistory(inSpace: spaceID, limit: 500) ?? []
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
    /// - Parameter window: the window the bar was opened over. It scopes the
    ///   whole bar: only the window's **active Space** contributes — its open
    ///   tabs, history, and archive. Nothing from another Space leaks in, so
    ///   typing never silently switches Space (4.4). The window's *kind* is
    ///   enforced by construction: a private window's active Space is its own
    ///   private Space, a normal window's is a normal one, so the filter cannot
    ///   surface the other kind.
    public func suggestions(for query: String, in window: WindowState? = nil) -> [Suggestion] {
        let target = window ?? primaryWindow
        let isPrivateWindow = target.isPrivate
        let spaceID = target.activeSpaceID
        let searchableTabs = tabs.filter { $0.spaceID == spaceID }
        return CommandBarRanking.suggestions(
            for: CommandBarInput(
                query: query,
                // Only the active Space's tabs, in that Space's own window.
                tabs: searchableTabs,
                spaceNames: Dictionary(
                    uniqueKeysWithValues: spaces.map { ($0.id, $0.name) }
                ),
                // A private window shows no history or archive: both are read
                // from disk, and neither has anything of this session in it.
                history: isPrivateWindow ? [] : cachedHistory,
                archived: isPrivateWindow
                    ? []
                    : cachedArchive.filter { $0.spaceID == spaceID },
                now: clock.now,
                searchTemplate: searchEngine.queryTemplate
            )
        )
    }

    /// - Parameter destination: where the result goes, decided by the shortcut
    ///   that opened the bar (4.4) — or forced to `.newTab` by `Cmd+Enter`.
    public func activate(
        _ suggestion: Suggestion,
        destination: ActivationDestination = .newTab,
        in window: WindowState
    ) {
        switch suggestion.kind {
        case .openTab(let tabID, let spaceID, _):
            // Choosing an already-open tab always switches to it rather than
            // opening a duplicate (4.4) — except when splitting, where the tab
            // is *moved* into the split exactly as dragging it there would
            // (4.5). Either way the tab never ends up existing twice.
            if destination == .newPane, let target = window.selectedTabID, target != tabID {
                split(target, byMoving: tabID, in: window)
            } else {
                if spaceID != window.activeSpaceID { selectSpace(spaceID, in: window) }
                select(tabID, in: window)
            }

        case .history(let url), .navigate(let url), .search(_, let url):
            open(url, destination: destination, in: window)

        case .archived(let tab):
            restoreArchived(tab, in: window)

        case .command(let command):
            run(command, in: window)
        }
    }

    private func open(_ url: URL, destination: ActivationDestination, in window: WindowState) {
        switch destination {
        case .newPane where window.selectedTabID != nil:
            splitSelectedTab(url: url, in: window)
        // With no tab to split or navigate, there is only one sensible landing
        // place and it is a new tab.
        case .newTab, .newPane:
            newTab(url: url, in: window)
        case .currentTab:
            if selectedTab(in: window) == nil {
                newTab(url: url, in: window)
            } else {
                navigate(to: url, in: window)
            }
        }
    }

    private func run(_ command: ChordCommand, in window: WindowState) {
        switch command {
        case .newTab: newTab(in: window)
        case .closeTab: window.selectedTabID.map { closeTab($0, in: window) }
        case .newSpace: addSpace(in: window)
        case .reload: reload(in: window)
        }
    }

    // MARK: - History recording

    /// Called when a navigation settles. Skipped for blank and error pages so
    /// the command bar does not learn junk. Recorded against the tab's Space so
    /// history stays per-Space.
    func recordVisit(url: URL, title: String, spaceID: UUID) {
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        // A private Space keeps no history. The guard is here rather than at the
        // caller so any future caller inherits it — there is exactly one today.
        guard !isPrivate(spaceID: spaceID) else { return }

        let now = clock.now
        Task { [historyRepository] in
            do {
                try await historyRepository?.recordVisit(
                    url: url, title: title, spaceID: spaceID, at: now
                )
            } catch {
                Log.store.error("history write failed: \(String(describing: error))")
            }
        }
    }
}
