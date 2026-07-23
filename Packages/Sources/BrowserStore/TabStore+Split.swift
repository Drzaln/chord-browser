import BrowserCore
import BrowserEngine
import Foundation

/// Split view (4.5). A tab with several panes — never a separate type.
@MainActor
extension TabStore {

    /// Splits the selected tab, adding a pane to the right of the focused one.
    ///
    /// Capped at `SplitLayout.maxPanes`; beyond that the command does nothing
    /// rather than silently replacing a pane.
    public func splitSelectedTab(url: URL? = nil) {
        guard let tabID = selectedTabID else { return }
        split(tabID, url: url)
    }

    public func split(_ tabID: UUID, url: URL? = nil) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        guard tabs[index].panes.count < SplitLayout.maxPanes else {
            Log.store.notice("split refused: tab already has \(SplitLayout.maxPanes) panes")
            return
        }

        let insertAfter = tabs[index].panes.firstIndex { $0.id == tabs[index].focusedPaneID }
            ?? tabs[index].panes.count - 1

        let pane = Pane(url: url ?? Self.defaultNewTabURL)
        tabs[index].panes.insert(pane, at: insertAfter + 1)

        // A new pane starts life resolved: nothing is stored for it, so a disk
        // read would only cost a frame of withheld surface (see M4 notes).
        markInteractionStateResolved(pane.id)

        // Equal widths on split. Preserving the old proportions would make the
        // new pane a sliver of whatever was focused.
        applyFractions(SplitLayout.equalFractions(count: tabs[index].panes.count), toTabAt: index)

        tabs[index].focusedPaneID = pane.id
        scheduleSave()
    }

    /// Removes a pane. Closing down to one converts the tab back to a normal
    /// tab (4.5); closing the last pane closes the tab.
    public func closePane(_ paneID: UUID) {
        guard let index = tabs.firstIndex(where: { tab in
            tab.panes.contains { $0.id == paneID }
        }) else { return }

        guard tabs[index].panes.count > 1 else {
            closeTab(tabs[index].id)
            return
        }

        // The web view goes before the model does — it belongs to this pane and
        // nothing will reclaim it once the pane is gone.
        captureInteractionState(for: paneID)
        engine.evict(paneID: paneID)
        runtimes[paneID] = nil

        let removedPosition = tabs[index].panes.firstIndex { $0.id == paneID }
        tabs[index].panes.removeAll { $0.id == paneID }

        // Survivors keep their relative widths rather than snapping to equal.
        applyFractions(
            SplitLayout.normalized(tabs[index].panes.map(\.widthFraction)), toTabAt: index
        )

        if tabs[index].focusedPaneID == paneID {
            let fallback = removedPosition.map { min($0, tabs[index].panes.count - 1) } ?? 0
            tabs[index].focusedPaneID = tabs[index].panes[fallback].id
        }
        scheduleSave()
    }

    /// Focus follows the pane the user last interacted with; navigation and
    /// back/forward act on it alone (4.5).
    public func focusPane(_ paneID: UUID) {
        guard let index = tabs.firstIndex(where: { tab in
            tab.panes.contains { $0.id == paneID }
        }) else { return }
        guard tabs[index].focusedPaneID != paneID else { return }

        tabs[index].focusedPaneID = paneID
        scheduleSave()
    }

    /// Drags the divider to the right of pane `index` within `tabID`.
    ///
    /// `delta` is a fraction of the tab's width, so the caller converts points
    /// to a fraction and this stays free of view geometry.
    public func resizePanes(in tabID: UUID, dividerAfter index: Int, by delta: Double) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        let current = tabs[tabIndex].panes.map(\.widthFraction)
        let updated = SplitLayout.resizing(current, dividerAfter: index, by: delta)
        guard updated != current else { return }

        applyFractions(updated, toTabAt: tabIndex)
        // Dragging emits a stream of these; the 2 s debounce coalesces them so
        // a drag is one write, not one per frame (6.5).
        scheduleSave()
    }

    private func applyFractions(_ fractions: [Double], toTabAt index: Int) {
        for (position, fraction) in fractions.enumerated()
        where tabs[index].panes.indices.contains(position) {
            tabs[index].panes[position].widthFraction = fraction
        }
    }
}
