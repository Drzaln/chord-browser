import ChordCore
import Foundation

/// Walking the sidebar's tab list from the keyboard (gn0.11).
///
/// The keyboard has its own cursor, separate from the selection: arrowing
/// through thirty tabs must not load thirty pages. Return selects the row the
/// cursor is on; Delete closes it.
public enum SidebarNavigation {
    /// The row the cursor lands on. It starts from the cursor, or from the
    /// selected tab when there is no cursor yet, and stops at either end
    /// rather than wrapping.
    public static func move(
        from cursor: UUID?, selected: UUID?, in order: [UUID], by delta: Int
    ) -> UUID? {
        guard !order.isEmpty else { return nil }
        let start = cursor.flatMap(order.firstIndex(of:))
            ?? selected.flatMap(order.firstIndex(of:))
        guard let start else {
            // Nothing to start from: the first row going down, the last going up.
            return delta >= 0 ? order.first : order.last
        }
        // First key press from the selection puts the cursor on it.
        if cursor == nil || order.firstIndex(of: cursor!) == nil { return order[start] }
        return order[min(max(start + delta, 0), order.count - 1)]
    }

    /// Where the cursor goes when its row is closed: the row that takes its
    /// place, else the one before, else nowhere.
    public static func afterClosing(_ id: UUID, in order: [UUID]) -> UUID? {
        guard let index = order.firstIndex(of: id) else { return nil }
        if index + 1 < order.count { return order[index + 1] }
        return index > 0 ? order[index - 1] : nil
    }
}

extension TabStore {
    /// The window's tab rows in the order the sidebar shows them: Pinned tabs,
    /// then each open folder's tabs, then the unpinned tabs. Favourite tiles
    /// are a grid, not rows, and are not part of the walk.
    public func sidebarRowOrder(in window: WindowState) -> [UUID] {
        var order = bookmarkedTabs(in: window).map(\.id)
        for folder in folders(in: window) where !folder.isCollapsed {
            order += tabs(inFolder: folder.id).map(\.id)
        }
        order += unpinnedTabs(in: window).map(\.id)
        return order
    }
}
