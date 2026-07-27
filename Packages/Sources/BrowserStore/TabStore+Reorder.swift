import BrowserCore
import Foundation

/// Cross-section drag-and-drop in the sidebar (4.1): reorder within a section,
/// drag across sections to change placement, drag onto a Space to move Spaces.
///
/// The gesture is AppKit — the row is already a `TabDragSource`, so the sidebar
/// only needs *destinations* beside it, not a second mechanism (see "How
/// drag-to-split works"). This file is the model side: where a dropped tab lands
/// and how the section renumbers. Moving between Spaces stays in
/// `TabStore.moveTab(_:toSpace:)`, which already tears the view down first.
@MainActor
extension TabStore {

    /// The three placement tiers a drag can land a tab in.
    public enum PlacementSection: Sendable, Equatable {
        /// The favourites icon grid.
        case favourite
        /// Arc-style *Pinned* tabs (the list section).
        case pinned
        /// Loose, sweep-eligible tabs.
        case ephemeral
    }

    /// Places `tabID` into a section of its own Space at `index`, renumbering
    /// that section densely so its order stays a clean `0..<n`.
    ///
    /// A drop into the tab's current section is a reorder; a change of section
    /// re-places it as it moves — the one place a drag both re-sections and
    /// re-orders in a single gesture. The source section is left as-is: its
    /// orders stay monotonic with a gap, which `visibleTabs` sorts correctly, so
    /// there is no need to renumber a section the drop did not touch.
    public func reorderTab(_ tabID: UUID, to section: PlacementSection, at index: Int) {
        guard let moving = tabs.first(where: { $0.id == tabID }) else { return }
        let spaceID = moving.spaceID

        var members = tabs
            .filter { $0.spaceID == spaceID && self.section(of: $0.placement) == section && $0.id != tabID }
            .sorted { $0.placement.order < $1.placement.order }
            .map(\.id)

        let clamped = max(0, min(index, members.count))
        members.insert(tabID, at: clamped)

        // A tab entering the Pinned section is pinned at wherever it currently
        // sits; one already there keeps its existing home.
        let home = moving.placement.homeURL ?? moving.focusedPane.url

        for (order, id) in members.enumerated() {
            guard let idx = tabs.firstIndex(where: { $0.id == id }) else { continue }
            switch section {
            case .favourite:
                let existingHome = tabs[idx].placement.homeURL
                    ?? (id == tabID ? home : tabs[idx].focusedPane.url)
                tabs[idx].placement = .pinned(order: order, homeURL: existingHome)
            case .pinned:
                let existingHome = tabs[idx].placement.homeURL
                    ?? (id == tabID ? home : tabs[idx].focusedPane.url)
                tabs[idx].placement = .bookmarked(order: order, homeURL: existingHome)
            case .ephemeral:
                tabs[idx].placement = .ephemeral(order: order)
            }
        }
        scheduleSave()
    }

    /// Back-compat two-way entry point for the favourites/ephemeral drag, which
    /// predates the Pinned tier. `pinned` here means the favourites grid.
    public func reorderTab(_ tabID: UUID, toPinned pinned: Bool, at index: Int) {
        reorderTab(tabID, to: pinned ? .favourite : .ephemeral, at: index)
    }

    private func section(of placement: TabPlacement) -> PlacementSection {
        if placement.isPinned { return .favourite }
        if placement.isBookmarked { return .pinned }
        return .ephemeral
    }
}

// MARK: - Drops that may cross a window

@MainActor
extension TabStore {

    /// A tab dropped into `window`'s sidebar, from anywhere — the same window,
    /// or another one showing a different Space.
    ///
    /// This is the entry point the sidebar uses instead of `reorderTab` directly,
    /// because a drop no longer implies "within this tab's own Space". Dragging
    /// between two windows in *different* Spaces is a Space change, and a Space
    /// change swaps the data store out from under the page — so it asks first
    /// (`PendingTabMove`) rather than silently signing the user out.
    ///
    /// Two windows in the *same* Space show the same list, so a drop between them
    /// is an ordinary reorder plus selecting what the user just dragged.
    public func dropTab(
        _ tabID: UUID,
        into section: PlacementSection,
        at index: Int,
        in window: WindowState
    ) {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let destination = activeSpace(in: window)
        else { return }

        guard tab.spaceID != destination.id else {
            reorderTab(tabID, to: section, at: index)
            select(tabID, in: window)
            return
        }

        window.pendingTabMove = PendingTabMove(
            id: tabID,
            toSpaceID: destination.id,
            destination: .section(section, index: index),
            fromSpaceName: spaces.first { $0.id == tab.spaceID }?.name ?? "another Space",
            toSpaceName: destination.name,
            tabTitle: tab.focusedPane.title.isEmpty
                ? (tab.focusedPane.url.host() ?? "this tab")
                : tab.focusedPane.title
        )
    }

    /// A tab dropped onto a Space *button* in the switcher. Moving into that Space
    /// is a Space change like any other — it swaps the data store out from under
    /// the page — so it prompts first, the way the sidebar and split drops already
    /// do. This was the one cross-Space drag that used to move silently.
    ///
    /// A drop onto the tab's own Space is a no-op: it is already there.
    public func dropTab(_ tabID: UUID, ontoSpace spaceID: UUID, in window: WindowState) {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let destination = spaces.first(where: { $0.id == spaceID }),
              tab.spaceID != spaceID
        else { return }

        window.pendingTabMove = PendingTabMove(
            id: tabID,
            toSpaceID: spaceID,
            destination: .space,
            fromSpaceName: spaces.first { $0.id == tab.spaceID }?.name ?? "another Space",
            toSpaceName: destination.name,
            tabTitle: tab.focusedPane.title.isEmpty
                ? (tab.focusedPane.url.host() ?? "this tab")
                : tab.focusedPane.title
        )
    }

    /// The user accepted the move. Changes the tab's Space — which evicts its
    /// panes, so the page reloads against the destination's cookies — then places
    /// it where it was dropped and selects it.
    public func confirmPendingTabMove(in window: WindowState) {
        guard let pending = window.pendingTabMove else { return }
        window.pendingTabMove = nil

        switch pending.destination {
        case .section(let section, let index):
            moveTab(pending.id, toSpace: pending.toSpaceID, in: window)
            // After the Space change, so the section renumbering happens among
            // the destination's tabs rather than the ones it just left.
            reorderTab(pending.id, to: section, at: index)
            select(pending.id, in: window)

        case .splitInto(let targetID):
            // The move is implicit here — `split(_:byMoving:)` closes the source
            // and rebuilds its URL as a pane of the target, which already puts
            // the page in the target's Space and its data store.
            split(targetID, byMoving: pending.id, in: window, confirmed: true)

        case .space:
            // A plain send-to-Space: keep the tab's placement kind, no slot to
            // renumber into. Matches the pre-prompt behaviour exactly.
            moveTab(pending.id, toSpace: pending.toSpaceID, in: window)
        }
    }

    /// Dismissed without moving. The tab stays exactly where it was.
    public func cancelPendingTabMove(in window: WindowState) {
        window.pendingTabMove = nil
    }
}
