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
        littleChordPages[pane.id] = (title: "", favicon: nil)
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
    /// The tab takes the panel's pane, id and all, so it surfaces the web view
    /// the panel was showing: the page carries on where it was — scroll, form
    /// contents, playback — instead of loading again. Same hand-over a
    /// `window.open()` popup gets (`paneRequestedPopup`).
    ///
    /// Only within one Space, though. A view is bound to the data store of the
    /// Space it was built in, so a panel promoted into a window showing a
    /// different Space gets a fresh view there and the page does reload.
    @discardableResult
    public func promoteLittleChord(_ pane: Pane, in window: WindowState) -> UUID? {
        // Where the panel has navigated to, not where it opened: following a
        // couple of links and then promoting should keep where you got to.
        let url = runtime(for: pane.id).currentURL ?? pane.url

        guard engine.hasLiveView(paneID: pane.id),
              let spaceID = engine.spaceID(forPane: pane.id),
              spaceID == activeSpace(in: window)?.id
        else {
            discardLittleChord(pane)
            newTab(url: url, in: window)
            return window.selectedTabID
        }

        // The page reported its title and icon while it was in no tab, and it
        // will not report them again without a load.
        let page = littleChordPages.removeValue(forKey: pane.id)
        let title = page?.title ?? ""
        let adopted = Pane(id: pane.id, url: url, title: title, faviconData: page?.favicon)
        let tabID = insertTab(panes: [adopted], in: window, selecting: true)

        // Nor will it settle again, which is when a visit is recorded. A page
        // still loading records itself the usual way once it finishes.
        let isLoading = runtime(for: pane.id).isLoading
        if isLoading || title.isEmpty {
            pendingHistoryURL[pane.id] = url
        } else {
            recordVisit(url: url, title: title, spaceID: spaceID)
        }
        return tabID
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
        discardPanes([paneID])
    }
}
