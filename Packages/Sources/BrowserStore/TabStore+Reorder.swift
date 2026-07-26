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
    public enum PlacementSection: Sendable {
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
