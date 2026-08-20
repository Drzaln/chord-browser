import ChordCore
import ChordEngine
import Foundation

/// Find-in-page (§8, M6).
///
/// Searches the *focused pane* of the window's selected tab, not the tab: in a
/// split, Cmd+F means the pane you are looking at, and searching all of them
/// would scroll panes you are not.
///
/// Every entry point takes the window whose bar it is — the bar, its query, and
/// its result are window state. Only the engine call is shared, and it is
/// addressed by pane, so two windows searching two different panes cannot
/// collide. Two windows searching the *same* pane would, since WebKit keeps one
/// find state per web view, but that needs one tab shown twice and costs only
/// the highlight.
@MainActor
extension TabStore {

    public func showFindBar(in window: WindowState) {
        window.isFindBarVisible = true
        // Deliberately keeps `findText`. Reopening the bar with the last query
        // still in it is what every other find bar does, and re-typing a long
        // term because you dismissed the bar is a small daily annoyance.
        window.findFoundMatch = nil
    }

    public func hideFindBar(in window: WindowState) {
        window.isFindBarVisible = false
        window.findFoundMatch = nil
        if let paneID = focusedPaneIDForFind(in: window) {
            // Otherwise the last match stays highlighted on a page whose find
            // bar is gone.
            engine.clearFind(in: paneID)
        }
    }

    /// Runs the current query from the top. Called as the user types.
    public func findNext(in window: WindowState) {
        runFind(backwards: false, in: window)
    }

    public func findPrevious(in window: WindowState) {
        runFind(backwards: true, in: window)
    }

    private func runFind(backwards: Bool, in window: WindowState) {
        guard let paneID = focusedPaneIDForFind(in: window) else { return }
        let text = window.findText

        guard !text.isEmpty else {
            // An empty field is not "no matches" — it is no query. Showing
            // "not found" while the user is deleting their search term is
            // noise, and the red flash on every backspace is worse.
            window.findFoundMatch = nil
            engine.clearFind(in: paneID)
            return
        }

        window.findTask?.cancel()
        window.findTask = Task { @MainActor in
            let found = await engine.find(text, in: paneID, backwards: backwards)
            // Every keystroke issues a new find and cancels this one, so a
            // superseded query must not report its answer for text the user
            // has already moved past. Cancellation is the whole guard: there is
            // no path that changes `findText` without also starting a find.
            guard !Task.isCancelled else { return }
            window.findFoundMatch = found
        }
    }

    private func focusedPaneIDForFind(in window: WindowState) -> UUID? {
        selectedTab(in: window)?.focusedPaneID
    }
}
