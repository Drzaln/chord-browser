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

    /// Places `tabID` into a section of its own Space at `index`, renumbering
    /// that section densely so its order stays a clean `0..<n`.
    ///
    /// `pinned == the tab's current section` is a reorder; a change of section
    /// pins or unpins it as it moves — the one place a drag both re-sections and
    /// re-orders in a single gesture. The source section is left as-is: its
    /// orders stay monotonic with a gap, which `visibleTabs` sorts correctly, so
    /// there is no need to renumber a section the drop did not touch.
    public func reorderTab(_ tabID: UUID, toPinned pinned: Bool, at index: Int) {
        guard let moving = tabs.first(where: { $0.id == tabID }) else { return }
        let spaceID = moving.spaceID

        var section = tabs
            .filter { $0.spaceID == spaceID && $0.placement.isPinned == pinned && $0.id != tabID }
            .sorted { $0.placement.order < $1.placement.order }
            .map(\.id)

        let clamped = max(0, min(index, section.count))
        section.insert(tabID, at: clamped)

        for (order, id) in section.enumerated() {
            guard let idx = tabs.firstIndex(where: { $0.id == id }) else { continue }
            tabs[idx].placement = pinned ? .pinned(order: order) : .ephemeral(order: order)
        }
        scheduleSave()
    }
}
