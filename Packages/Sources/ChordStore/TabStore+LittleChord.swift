import ChordCore
import ChordEngine
import Foundation

/// Little Chord (4.6): a link from another app opens in a floating panel that can
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
    public func makeLittleChordPane(url: URL) -> Pane {
        let pane = Pane(url: url)
        // Nothing is stored for it, so do not withhold its surface for a disk
        // read that can only come back empty.
        markInteractionStateResolved(pane.id)
        return pane
    }

    /// The surface for the floating panel, in a specific Space.
    ///
    /// The Space decides which `WKWebsiteDataStore` the view uses, so the caller
    /// picks it: a link clicked in a favourite should surface in the Space that
    /// favourite lives in (already logged in to whatever that Space is). Falls
    /// back to the primary window's active Space when no Space is given — the
    /// Little Chord path, whose `promoteLittleChord` targets that window anyway.
    public func littleChordSurface(for pane: Pane, in spaceID: UUID? = nil) -> AnyWebSurface? {
        let space = spaceID.flatMap { id in spaces.first { $0.id == id } }
            ?? activeSpace(in: primaryWindow)
        guard let space else {
            Log.store.error("no active space; refusing to open a Little Chord panel")
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
    public func promoteLittleChord(_ pane: Pane, in window: WindowState) -> UUID? {
        let url = runtime(for: pane.id).currentURL ?? pane.url

        // The panel's own web view belongs to the panel. The new tab builds its
        // own, in the same Space — cheaper than trying to re-parent a live view
        // across two window hierarchies.
        discardLittleChord(pane)

        newTab(url: url, in: window)
        return window.selectedTabID
    }

    /// Esc, or the panel closing. Tears the web view down: nothing else refers
    /// to this pane, so without it the view would leak for the app's lifetime.
    public func discardLittleChord(_ pane: Pane) {
        discardLittleChord(paneID: pane.id)
    }

    /// Tears a panel's web view down by pane id alone — the shape the engine's
    /// swipe-to-close callback arrives in, where the store has the id but not
    /// the `Pane` object (the app layer owns the panel).
    public func discardLittleChord(paneID: UUID) {
        engine.evict(paneID: paneID)
        runtimes[paneID] = nil
        forgetStateResolution(forPanes: [paneID])
    }
}
