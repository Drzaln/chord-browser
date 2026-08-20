import ChordCore
import Foundation

/// The History window's data actions (non-spec: user-requested). The window
/// reads the full recorded history, opens an entry as a tab, and deletes
/// selected entries; the Store is the one place that already holds the history
/// repository.
@MainActor
extension TabStore {

    /// The active Space's recorded visits, most-recent first. History is
    /// per-Space, so the window shows only where you've been *in this Space*.
    /// Bounded so an enormous history cannot stall the window; 5,000 rows is far
    /// past what the list shows at once and still cheap to load.
    public func loadFullHistory(
        limit: Int = 5_000, in window: WindowState
    ) async -> [HistoryEntry] {
        guard let spaceID = activeSpace(in: window)?.id else { return [] }
        do {
            return try await historyRepository?.recentHistory(inSpace: spaceID, limit: limit) ?? []
        } catch {
            Log.store.error("history window load failed: \(String(describing: error))")
            return []
        }
    }

    /// Opens a history entry in a new tab. New tab, not the current one: the
    /// History window is a place you go looking, and clobbering what you were on
    /// is the surprise users hate.
    public func openHistoryEntry(_ url: URL, in window: WindowState) {
        newTab(url: url, in: window)
    }

    /// Deletes the given entries by id. The window removes them from its own list
    /// optimistically; this makes the removal durable. Also drops them from the
    /// in-memory command-bar cache so a bar opened right after does not resurrect
    /// them.
    public func deleteHistory(ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        let removed = Set(ids)
        cachedHistory.removeAll { removed.contains($0.id) }
        do {
            try await historyRepository?.deleteHistory(ids: ids)
        } catch {
            Log.store.error("history delete failed: \(String(describing: error))")
        }
    }

    /// Clears the active Space's history — the History window's "Clear All".
    /// Scoped to this Space, unlike Settings' global clear-browsing-data.
    public func clearActiveSpaceHistory(in window: WindowState) async {
        guard let spaceID = activeSpace(in: window)?.id else { return }
        cachedHistory.removeAll()
        do {
            try await historyRepository?.deleteAllHistory(inSpace: spaceID)
        } catch {
            Log.store.error("history clear (space) failed: \(String(describing: error))")
        }
    }
}
