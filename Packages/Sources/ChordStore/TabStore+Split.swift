import ChordCore
import ChordEngine
import Foundation

/// Split view (4.5). A tab with several panes — never a separate type.
@MainActor
extension TabStore {

    /// Splits the selected tab, adding a pane to the right of the focused one.
    ///
    /// Capped at `SplitLayout.maxPanes`; beyond that the command does nothing
    /// rather than silently replacing a pane.
    public func splitSelectedTab(url: URL? = nil, in window: WindowState) {
        guard let tabID = window.selectedTabID else { return }
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

        let pane = Pane(url: url ?? resolvedNewTabURL)
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

    // MARK: - Drag session

    /// Called when a sidebar row starts being dragged.
    ///
    /// The content area needs to know a tab is in flight: `WKWebView` registers
    /// for dragged types itself and sits above our drop target, so it swallows
    /// the drop. The fix is a drop layer that only exists — and only takes hit
    /// tests — while a drag is actually happening, which is what this flag
    /// drives. It must be cleared even when the drag is cancelled, or that
    /// layer would go on eating clicks meant for the page.
    public func beginTabDrag(_ tabID: UUID) {
        draggingTabID = tabID
    }

    public func endTabDrag() {
        draggingTabID = nil
    }

    /// Drags a sidebar tab into another tab, making a split of it (4.5).
    ///
    /// The dragged tab is *moved*, not copied: it stops being its own row and
    /// becomes a pane. Copying would leave two rows showing the same page with
    /// no way to tell them apart.
    /// - Parameter confirmed: set once the user has accepted a cross-Space move.
    ///   Dragging a tab from a window in another Space rebuilds its page against
    ///   the target Space's cookie store, so it asks first — the same prompt the
    ///   sidebar drop uses.
    public func split(
        _ tabID: UUID,
        byMoving sourceTabID: UUID,
        in window: WindowState,
        confirmed: Bool = false
    ) {
        guard tabID != sourceTabID,
              tabs.contains(where: { $0.id == tabID }),
              let source = tabs.first(where: { $0.id == sourceTabID })
        else { return }

        guard let target = tabs.first(where: { $0.id == tabID }),
              target.panes.count < SplitLayout.maxPanes
        else {
            Log.store.notice("drop refused: target tab already has \(SplitLayout.maxPanes) panes")
            return
        }

        // Newly reachable with a second window: before, the sidebar only ever
        // showed one Space, so a drag could not carry a tab across one. It can
        // now, and it is the same data-store change the sidebar drop warns about.
        if !confirmed, source.spaceID != target.spaceID {
            window.pendingTabMove = PendingTabMove(
                id: sourceTabID,
                toSpaceID: target.spaceID,
                destination: .splitInto(tabID: tabID),
                fromSpaceName: spaces.first { $0.id == source.spaceID }?.name
                    ?? "another Space",
                toSpaceName: spaces.first { $0.id == target.spaceID }?.name
                    ?? "this Space",
                tabTitle: source.focusedPane.title.isEmpty
                    ? (source.focusedPane.url.host() ?? "this tab")
                    : source.focusedPane.title
            )
            return
        }

        // Take the URL before closing, and let the source's own state go: the
        // new pane starts fresh rather than inheriting a blob keyed to a pane
        // that no longer exists.
        let url = source.focusedPane.url

        // The source tab is *moved* into the target, so it must go entirely —
        // even if it was itself a split. `closeTab` would only close the
        // focused pane of a split; the whole-tab variant is required here.
        closeTabRemovingEveryPane(sourceTabID, in: window)
        // closeTab may have moved the selection; the split must still land on
        // the tab that was dropped onto.
        window.selectedTabID = tabID
        split(tabID, url: url)
    }

    /// Removes a pane. Closing down to one converts the tab back to a normal
    /// tab (4.5); closing the last pane closes the tab.
    public func closePane(_ paneID: UUID, in window: WindowState) {
        guard let index = tabs.firstIndex(where: { tab in
            tab.panes.contains { $0.id == paneID }
        }) else { return }

        guard tabs[index].panes.count > 1 else {
            closeTab(tabs[index].id, in: window)
            return
        }

        // The web view goes before the model does — it belongs to this pane and
        // nothing will reclaim it once the pane is gone. The model pane is
        // captured *first*: tearing the view down navigates it to `about:blank`
        // (`tearDown`), whose KVO snapshot would otherwise overwrite this
        // pane's URL before the reopen could record it.
        let removedPosition = tabs[index].panes.firstIndex { $0.id == paneID }
        guard let removedPosition else { return }
        let closedPane = tabs[index].panes[removedPosition]

        captureInteractionState(for: paneID)
        engine.evict(paneID: paneID)
        engine.forget(paneID: paneID)
        runtimes[paneID] = nil

        tabs[index].panes.remove(at: removedPosition)

        // Cmd+Shift+T can undo a pane close: record the pane and where it sat,
        // so the reopen re-inserts it at that position (Arc behaviour). Never
        // for a private pane — the same store-wide reason whole private tabs are
        // excluded from `recentlyClosed`.
        if !isPrivate(spaceID: tabs[index].spaceID) {
            recentlyClosed.append(.pane(closedPane, tabID: tabs[index].id, position: removedPosition))
            if recentlyClosed.count > Self.recentlyClosedLimit { recentlyClosed.removeFirst() }
        }

        // Survivors keep their relative widths rather than snapping to equal.
        applyFractions(
            SplitLayout.normalized(tabs[index].panes.map(\.widthFraction)), toTabAt: index
        )

        if tabs[index].focusedPaneID == paneID {
            let fallback = min(removedPosition, tabs[index].panes.count - 1)
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
        resizePanes(in: tabID, dividerAfter: index, by: delta,
                    from: tabs[tabIndex].panes.map(\.widthFraction))
    }

    /// Applies a drag against the widths as they were when the drag *started*.
    ///
    /// A drag reports its translation from the point it began, so applying that
    /// to a moving baseline compounds it and the divider runs away from the
    /// cursor. The caller snapshots the fractions on the first change event and
    /// passes the same `base` for the rest of the drag.
    public func resizePanes(
        in tabID: UUID, dividerAfter index: Int, by delta: Double, from base: [Double]
    ) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }),
              base.count == tabs[tabIndex].panes.count
        else { return }

        let updated = SplitLayout.resizing(base, dividerAfter: index, by: delta)
        guard updated != tabs[tabIndex].panes.map(\.widthFraction) else { return }

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

    /// Re-inserts a closed pane into its tab at its previous position.
    ///
    /// A no-op when the tab is gone (closed again, or its Space was deleted) —
    /// the pane has nothing to return to. The pane's saved URL is carried, but
    /// its interaction state was pruned on close, so it reloads rather than
    /// restoring scroll — the same trade the tab reopen makes.
    func reopenClosedPane(_ pane: Pane, tabID: UUID, position: Int, in window: WindowState) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        guard tabs[index].panes.count < SplitLayout.maxPanes else { return }

        let insertAt = min(position, tabs[index].panes.count)
        tabs[index].panes.insert(pane, at: insertAt)
        applyFractions(
            SplitLayout.normalized(tabs[index].panes.map(\.widthFraction)), toTabAt: index
        )
        tabs[index].focusedPaneID = pane.id
        markInteractionStateResolved(pane.id)
        window.selectedTabID = tabID
        if tabs[index].spaceID != window.activeSpaceID {
            selectSpace(tabs[index].spaceID, in: window)
        }
        scheduleSave()
    }
}
