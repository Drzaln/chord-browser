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

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Metrics.contentCornerRadius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(
                    color: .black.opacity(Metrics.shadowOpacity),
                    radius: Metrics.shadowRadius,
                    y: 2
                )

            if let tab = store.selectedTab, let surface = store.surface(for: tab) {
                // Keyed by tab so switching swaps surfaces rather than
                // reconfiguring one in place.
                surface.id(tab.id)
            }
        }
        .padding(Metrics.contentInset)
    }
}
