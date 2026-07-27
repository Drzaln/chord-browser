import BrowserCore
import Foundation

/// A window held without keeping it alive. A window belongs to its SwiftUI
/// scene; the store only needs to reach the ones still on screen.
@MainActor
struct WeakWindow {
    weak var value: WindowState?
    init(_ value: WindowState) { self.value = value }
}

/// Keeping every window pointed at something real.
///
/// The window performing an action fixes its own selection with intent — closing
/// tab 3 selects tab 4, not "the first one". The *other* windows have no intent
/// to honour: all they need is to stop pointing at a tab or Space that no longer
/// exists. That asymmetry is why this is a separate pass rather than something
/// the mutations do for everyone.
@MainActor
extension TabStore {

    /// The window showing this tab, if any, ignoring `excluding`.
    ///
    /// The load-bearing question for multi-window: a `WKWebView` is an `NSView`
    /// and an `NSView` has exactly one superview, so a tab can be on screen in
    /// **at most one window**. Two windows selecting it does not show it twice —
    /// it shows in whichever rendered last and leaves the other blank.
    func windowShowing(_ tabID: UUID, excluding: WindowState? = nil) -> WindowState? {
        windows.first { $0 !== excluding && $0.selectedTabID == tabID }
    }

    /// Whether any window is showing this tab.
    ///
    /// The sweep's idea of "in use": a tab open in a second window is on screen
    /// however long ago the *first* window last touched it, and archiving it
    /// would close a page the user is reading.
    func isSelectedByAnyWindow(_ tabID: UUID) -> Bool {
        windows.contains { $0.selectedTabID == tabID }
    }

    /// The window showing this pane, for engine callbacks that arrive knowing
    /// only which pane they came from — `window.open()` must put its new tab in
    /// the window the page is actually displayed in.
    ///
    /// Falls back to the primary: a pane with no window is one that was evicted
    /// mid-callback, and dropping the tab entirely would be worse.
    func window(showingPane paneID: UUID) -> WindowState {
        let owner = tabs.first { tab in tab.panes.contains { $0.id == paneID } }
        guard let owner else { return primaryWindow }
        return windows.first { $0.selectedTabID == owner.id } ?? primaryWindow
    }

    /// The window a WebExtension should treat as showing this Space.
    ///
    /// WebExtensions model a Space as a window (ADR 011). With two real windows
    /// in one Space that is ambiguous, so the first one sitting there wins —
    /// stable, and right whenever only one window is in the Space.
    func window(inSpace spaceID: UUID) -> WindowState? {
        windows.first { activeSpace(in: $0)?.id == spaceID }
    }

    /// Re-points any window whose Space or selected tab has gone.
    ///
    /// Called after mutations that *remove* things (closing, sweeping, deleting a
    /// Space). Adding never invalidates a selection, so it does not need this.
    ///
    /// - Parameter acting: the window that performed the mutation, if any. It has
    ///   already chosen its own selection deliberately and must not be second-
    ///   guessed here.
    func reconcileWindows(excluding acting: WindowState? = nil) {
        for window in windows where window !== acting {
            reconcile(window)
        }
    }

    func reconcile(_ window: WindowState) {
        // A window whose Space was deleted follows the same rule as an orphaned
        // tab: re-home rather than blank out. A window that never had one — a
        // scene macOS restored before `restore()` had loaded any Spaces — is the
        // same case, and used to be missed because `nil` is not "invalid".
        let known = window.activeSpaceID.map { id in spaces.contains { $0.id == id } } ?? false
        if !known {
            window.activeSpaceID = spaces.first?.id
            window.selectedTabID = nil
        }

        guard let spaceID = window.activeSpaceID else {
            window.selectedTabID = nil
            return
        }

        let visible = tabs
            .filter { $0.spaceID == spaceID }
            .sorted { $0.placement.order < $1.placement.order }

        // Still showing something real, and no one else is showing it: leave it
        // alone. The common case — most mutations touch a tab nothing else is
        // looking at.
        if let selected = window.selectedTabID,
           visible.contains(where: { $0.id == selected }),
           windowShowing(selected, excluding: window) == nil {
            return
        }

        // Otherwise take the most recently used tab **no other window has**.
        // Sharing one would leave one of the two windows blank.
        let free = visible.filter { windowShowing($0.id, excluding: window) == nil }
        if let pick = free.max(by: { $0.lastAccessedAt < $1.lastAccessedAt }) {
            window.selectedTabID = pick.id
            return
        }

        // Every tab in this Space is on screen elsewhere, so this window needs
        // one of its own — which is what Cmd+N does anyway.
        window.selectedTabID = nil
        newTab(in: window)
    }
}
