import ChordCore
import ChordStore
import SwiftUI

/// The inset card that web content sits in.
///
/// The rounded corners are clipped by a container view inside the engine; the
/// shadow is drawn here, on a sibling behind the surface. Neither is applied to
/// the web view itself — doing that causes artifacts and can drop the
/// compositor fast path (BROWSER_SPEC 5).
struct WebContentCard: View {
    @Bindable var store: TabStore
    /// The window this view belongs to — its selection, its Space.
    @Bindable var windowState: WindowState
    /// True while the sidebar (and its loading bar) is off screen, so the card
    /// shows its own top-edge bar instead. See `ContentProgressBar`.
    var showsLoadingProgress: Bool = false

    var body: some View {
        Group {
            if let tab = store.selectedTab(in: windowState) {
                // Split view is just a tab with more panes (3.2), so there is one
                // path here rather than a normal case and a split case.
                SplitContentView(store: store, windowState: windowState, tab: tab)
                    .id(tab.id)
                    // Over the content rather than above it: pushing the page down
                    // to make room would relayout every pane for the length of a
                    // search.
                    .overlay(alignment: .topTrailing) {
                        if windowState.isFindBarVisible {
                            FindBar(store: store, windowState: windowState)
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: Metrics.contentCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .padding(Metrics.contentInset)
            }
        }
        // The collapsed-mode loading bar, clipped to the card so its ends don't
        // overhang the rounded corners. Clipping only the overlay leaves the web
        // surface's own corner handling untouched. Always mounted so the bar
        // fades in and out with the sidebar, rather than popping.
        .overlay(alignment: .top) {
            ContentProgressBar(
                store: store,
                windowState: windowState,
                visible: showsLoadingProgress,
                // The same Space accent the sidebar's bar uses, so both read as
                // the same indicator regardless of which is on screen.
                tint: SpaceTheme.accent(for: store.activeSpace(in: windowState) ?? Space.makeDefault())
            )
            .clipShape(
                RoundedRectangle(cornerRadius: Metrics.contentCornerRadius, style: .continuous)
            )
        }
    }
}
