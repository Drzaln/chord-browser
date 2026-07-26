import BrowserStore
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

    var body: some View {
        if let tab = store.selectedTab(in: windowState) {
            // Split view is just a tab with more panes (3.2), so there is one
            // path here rather than a normal case and a split case.
            SplitContentView(store: store, tab: tab)
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
}
