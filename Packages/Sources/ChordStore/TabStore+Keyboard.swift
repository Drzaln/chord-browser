import ChordCore
import Foundation

/// Keyboard-driven tab commands (non-spec: user-requested) — reopen the last
/// closed tab, and cycle the selection through the active Space's tabs.
@MainActor
extension TabStore {

    /// Reopens the most recently closed tab (Cmd+Shift+T), restoring its URLs,
    /// title, favicon, and pinned state. Lands in its original Space when that
    /// still exists, otherwise the active one — the same rule the archive
    /// restore uses (4.3).
    public func reopenLastClosedTab(in window: WindowState) {
        guard var tab = recentlyClosed.popLast() else { return }

        let spaceID = spaces.contains { $0.id == tab.spaceID }
            ? tab.spaceID
            : activeSpace(in: window)?.id
        guard let spaceID else { return }

        // Re-densify order within the destination Space's matching section, so a
        // reopened pinned tab rejoins the favourites and an ephemeral one the
        // list — never overlapping an existing row's slot.
        let pinned = tab.placement.isPinned
        let order = tabs
            .filter { $0.spaceID == spaceID && $0.placement.isPinned == pinned }
            .map(\.placement.order)
            .max()
            .map { $0 + 1 } ?? 0

        tab.spaceID = spaceID
        tab.placement = tab.placement.withOrder(order)
        tab.lastAccessedAt = clock.now

        // Its panes have no live web view and nothing stored (the blob was
        // pruned on close), so mark them resolved rather than spending a disk
        // read to rediscover that — matching `newTab`.
        for pane in tab.panes { markInteractionStateResolved(pane.id) }

        tabs.append(tab)
        if spaceID != window.activeSpaceID { selectSpace(spaceID, in: window) }
        window.selectedTabID = tab.id
        extensionHost?.extensionTabDidOpen(tab.id, inSpace: spaceID)
        scheduleSave()
    }

    /// The active Space's tabs in the order the sidebar shows them: favourites
    /// first, then the Pinned list, then the ephemeral list. This is the cycle
    /// order for the next/previous-tab shortcuts.
    private func cycleOrder(in window: WindowState) -> [Tab] {
        pinnedTabs(in: window) + bookmarkedTabs(in: window) + unpinnedTabs(in: window)
    }

    /// Selects the next tab in the window's Space, wrapping past the end
    /// (Ctrl+Tab / Cmd+Shift+]).
    public func selectNextTab(in window: WindowState) {
        cycleSelection(by: 1, in: window)
    }

    /// Selects the previous tab, wrapping past the start (Ctrl+Shift+Tab /
    /// Cmd+Shift+[).
    public func selectPreviousTab(in window: WindowState) {
        cycleSelection(by: -1, in: window)
    }

    private func cycleSelection(by delta: Int, in window: WindowState) {
        let list = cycleOrder(in: window)
        guard !list.isEmpty else { return }

        guard let current = window.selectedTabID,
              let index = list.firstIndex(where: { $0.id == current })
        else {
            select(list[0].id, in: window)
            return
        }

        let next = (index + delta + list.count) % list.count
        guard next != index else { return }
        select(list[next].id, in: window)
    }
}
