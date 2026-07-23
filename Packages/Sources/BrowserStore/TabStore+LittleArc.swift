import BrowserCore
import BrowserEngine
import Foundation

/// Little Arc (4.6): a link from another app opens in a floating panel that can
/// be promoted into a real tab.
///
/// The panel's page is an ordinary `Pane` that simply is not in any `Tab`. It
/// uses the active Space's data store, so a link arrives already logged in to
/// whatever that Space is logged in to — which is the whole point of opening it
/// here rather than in a fresh window.
@MainActor
extension TabStore {

    /// A pane for the floating panel. Not added to `tabs`, so it is invisible to
    /// the sidebar, the sweep, and persistence.
    public func makeLittleArcPane(url: URL) -> Pane {
        let pane = Pane(url: url)
        // Nothing is stored for it, so do not withhold its surface for a disk
        // read that can only come back empty.
        markInteractionStateResolved(pane.id)
        return pane
    }

    public func littleArcSurface(for pane: Pane) -> AnyWebSurface? {
        guard let space = activeSpace else {
            Log.store.error("no active space; refusing to open a Little Arc panel")
            return nil
        }
        return engine.surface(for: pane, in: space)
    }

    /// `Cmd+O` — promote the panel into a real tab in the active Space (4.6).
    ///
    /// Takes the URL the panel has actually navigated to, not the one it opened
    /// with: following a couple of links and then promoting should keep where
    /// you got to.
    @discardableResult
    public func promoteLittleArc(_ pane: Pane) -> UUID? {
        let url = runtime(for: pane.id).currentURL ?? pane.url

        // The panel's own web view belongs to the panel. The new tab builds its
        // own, in the same Space — cheaper than trying to re-parent a live view
        // across two window hierarchies.
        discardLittleArc(pane)

        newTab(url: url)
        return selectedTabID
    }

    /// Esc, or the panel closing. Tears the web view down: nothing else refers
    /// to this pane, so without it the view would leak for the app's lifetime.
    public func discardLittleArc(_ pane: Pane) {
        engine.evict(paneID: pane.id)
        runtimes[pane.id] = nil
        forgetStateResolution(forPanes: [pane.id])
    }
}
