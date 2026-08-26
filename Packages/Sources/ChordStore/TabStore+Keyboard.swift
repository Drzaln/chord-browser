import ChordCore
import Foundation

/// Keyboard-driven tab commands (non-spec: user-requested) — reopen the last
/// closed tab or pane, and the Arc-style most-recently-used Ctrl+Tab switcher.
@MainActor
extension TabStore {

    /// Reopens the most recently closed tab or pane (Cmd+Shift+T).
    ///
    /// A closed *tab* comes back with its URLs, title, favicon, and pinned
    /// state, in its original Space when that still exists, otherwise the
    /// active one — the same rule the archive restore uses (4.3). A closed
    /// *pane* goes back into its tab at the position it left (Arc behaviour).
    public func reopenLastClosedTab(in window: WindowState) {
        guard let closed = recentlyClosed.popLast() else { return }
        switch closed {
        case .tab(let tab):
            reopenTab(tab, in: window)
        case .pane(let pane, let tabID, let position):
            reopenClosedPane(pane, tabID: tabID, position: position, in: window)
        }
    }

    private func reopenTab(_ tab: Tab, in window: WindowState) {
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

        var tab = tab
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
        recordSelection(tab.id, replacing: nil, in: window)
        extensionHost?.extensionTabDidOpen(tab.id, inSpace: spaceID)
        scheduleSave()
    }

    // MARK: - Most-recently-used tab switching (Ctrl+Tab)

    /// The active Space's tabs the user has actually **opened** this session
    /// (their web view has been created), in most-recently-used order, most
    /// recent first — including the one currently on screen, which sorts first
    /// because `select` touched it. Restored-but-never-shown sidebar tabs do
    /// not appear, matching Arc's switcher. Ordering is `lastAccessedAt`, which
    /// `select` bumps on every activation, so it reads as "the tab I'm on, the
    /// one before it, the one before that, …".
    private func mruOrder(in window: WindowState) -> [Tab] {
        visibleTabs(in: window)
            .filter { openedPaneIDs.contains($0.focusedPaneID) }
            .sorted { lhs, rhs in
            // `sorted(by:)` is not stable, so equal timestamps (a FixedClock in
            // tests, two selections in the same real tick) need a deterministic
            // tiebreak or the order varies between runs.
            if lhs.lastAccessedAt != rhs.lastAccessedAt {
                return lhs.lastAccessedAt > rhs.lastAccessedAt
            }
            if lhs.placement.order != rhs.placement.order {
                return lhs.placement.order < rhs.placement.order
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Begins an Arc-style MRU tab-switch session: the Ctrl key went down, and
    /// the overlay appears listing the active Space's tabs in most-recently-used
    /// order with the current tab first (and highlighted). Nothing is selected
    /// yet — the first Tab press aims past the current tab at the one used just
    /// before, and releasing Ctrl commits whatever the cursor points at. A bare
    /// Ctrl tap (no Tab) commits nothing.
    public func beginMRUSwitch(in window: WindowState) {
        window.mruTabIDs = mruOrder(in: window).map(\.id)
        window.mruCursor = nil
        window.isMRUSessionPresented = true
    }

    /// Ctrl+Tab. With a session on screen (Ctrl held past the hold threshold), the
    /// first press aims at the most recent tab *other than* the one you're on
    /// and later presses walk down the list. With none — a quick tap, or the
    /// menu item — it is a plain Firefox-style switch to the most recent other
    /// tab, with no switcher overlay.
    public func selectNextTab(in window: WindowState) {
        guard window.isMRUSessionPresented else {
            quickSwitch(by: 1, in: window)
            return
        }
        advanceMRUCursor(by: 1, in: window)
    }

    /// Ctrl+Shift+Tab. Mirrors `selectNextTab`, walking up the MRU list instead
    /// of down, so the first press lands on the least-recent tab.
    public func selectPreviousTab(in window: WindowState) {
        guard window.isMRUSessionPresented else {
            quickSwitch(by: -1, in: window)
            return
        }
        advanceMRUCursor(by: -1, in: window)
    }

    /// A plain Ctrl+Tab tap: switch immediately to the neighbouring tab in MRU
    /// order — the most recent other tab for Ctrl+Tab, the least recent for
    /// Ctrl+Shift+Tab — without ever presenting the switcher. The current tab
    /// sits at index 0, so "next" is index 1.
    private func quickSwitch(by delta: Int, in window: WindowState) {
        let list = mruOrder(in: window)
        guard list.count > 1 else { return }
        let target = delta > 0 ? list[1].id : list[list.count - 1].id
        select(target, in: window)
    }

    /// Steps the overlay cursor one row, wrapping at both ends. The current tab
    /// sits at index 0 (it is the most recent), so the first press — cursor is
    /// `nil` — skips it: Ctrl+Tab aims at index 1, Ctrl+Shift+Tab at the least
    /// recent.
    private func advanceMRUCursor(by delta: Int, in window: WindowState) {
        let count = window.mruTabIDs.count
        guard count > 0 else { return }
        guard let current = window.mruCursor else {
            window.mruCursor = delta > 0 ? min(1, count - 1) : count - 1
            return
        }
        window.mruCursor = (current + delta + count) % count
    }

    /// The Ctrl key came up: commit the tab the cursor points at — if the user
    /// pressed Tab at all — and take the overlay away.
    public func commitMRUSwitch(in window: WindowState) {
        defer { endMRUSwitch(in: window) }
        guard let cursor = window.mruCursor,
              window.mruTabIDs.indices.contains(cursor)
        else { return }
        select(window.mruTabIDs[cursor], in: window)
    }

    /// Abandons the session without selecting anything — another key was pressed
    /// while Ctrl was held, or the window stopped being key.
    public func cancelMRUSwitch(in window: WindowState) {
        endMRUSwitch(in: window)
    }

    private func endMRUSwitch(in window: WindowState) {
        window.mruTabIDs = []
        window.mruCursor = nil
        window.isMRUSessionPresented = false
    }
}