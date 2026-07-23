import BrowserCore
import BrowserEngine
import Foundation

/// Find-in-page (§8, M6).
///
/// Searches the *focused pane* of the selected tab, not the tab: in a split,
/// Cmd+F means the pane you are looking at, and searching all of them would
/// scroll panes you are not.
@MainActor
extension TabStore {

    public func showFindBar() {
        isFindBarVisible = true
        // Deliberately keeps `findText`. Reopening the bar with the last query
        // still in it is what every other find bar does, and re-typing a long
        // term because you dismissed the bar is a small daily annoyance.
        findFoundMatch = nil
    }

    public func hideFindBar() {
        isFindBarVisible = false
        findFoundMatch = nil
        if let paneID = focusedPaneIDForFind {
            // Otherwise the last match stays highlighted on a page whose find
            // bar is gone.
            engine.clearFind(in: paneID)
        }
    }

    /// Runs the current query from the top. Called as the user types.
    public func findNext() { runFind(backwards: false) }
    public func findPrevious() { runFind(backwards: true) }

    private func runFind(backwards: Bool) {
        guard let paneID = focusedPaneIDForFind else { return }
        let text = findText

        guard !text.isEmpty else {
            // An empty field is not "no matches" — it is no query. Showing
            // "not found" while the user is deleting their search term is
            // noise, and the red flash on every backspace is worse.
            findFoundMatch = nil
            engine.clearFind(in: paneID)
            return
        }

        findTask?.cancel()
        findTask = Task { @MainActor in
            let found = await engine.find(text, in: paneID, backwards: backwards)
            // Every keystroke issues a new find and cancels this one, so a
            // superseded query must not report its answer for text the user
            // has already moved past. Cancellation is the whole guard: there is
            // no path that changes `findText` without also starting a find.
            guard !Task.isCancelled else { return }
            self.findFoundMatch = found
        }
    }

    private var focusedPaneIDForFind: UUID? {
        selectedTab?.focusedPaneID
    }
}
