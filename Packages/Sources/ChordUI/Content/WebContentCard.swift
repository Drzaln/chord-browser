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
    /// The card's inset from the window edges, and its corner radius. Both
    /// collapse to zero when the window is edge-to-edge (native fullscreen with
    /// the sidebar collapsed), so the page reaches the screen edges and the
    /// Space-tinted border disappears.
    var contentInset: CGFloat = Metrics.contentInset
    var contentCornerRadius: CGFloat = Metrics.contentCornerRadius

    var body: some View {
        Group {
            if let selectedID = windowState.selectedTabID,
               store.tabs.contains(where: { $0.id == selectedID }) {
                ZStack {
                    // Every open tab keeps a stable slot so its web view is never
                    // detached when the selection moves — a detach rejoins at 0×0
                    // and fires a resize that resets in-page SPA state (an
                    // Instagram carousel snaps back to slide 1). Only tabs whose
                    // pane already has a live view are mounted, so this never
                    // builds a view for a lazy/unopened tab, and the pool's cap
                    // still bounds how many are kept.
                    ForEach(mountedTabs) { mounted in
                        SplitContentView(
                            store: store, windowState: windowState, tab: mounted,
                            contentInset: contentInset, contentCornerRadius: contentCornerRadius,
                            isParked: mounted.id != selectedID
                        )
                        .id(mounted.id)
                        .allowsHitTesting(mounted.id == selectedID)
                        .accessibilityHidden(mounted.id != selectedID)
                        .zIndex(mounted.id == selectedID ? 1 : 0)
                    }
                }
                // Over the content rather than above it: pushing the page down
                // to make room would relayout every pane for the length of a
                // search.
                .overlay(alignment: .topTrailing) {
                    if windowState.isFindBarVisible {
                        FindBar(
                            store: store, windowState: windowState,
                            contentInset: contentInset
                        )
                    }
                }
            } else {
                // Arc: an empty content area blends with the chrome rather than
                // showing a bare page card — the active Space's gradient under
                // glass. On macOS 26 that glass is Liquid Glass (the system's
                // current material); earlier systems get the same gradient
                // under thin glass as the sidebar border.
                let space = store.activeSpace(in: windowState) ?? Space.makeDefault()
                let shape = RoundedRectangle(
                    cornerRadius: contentCornerRadius, style: .continuous
                )
                Group {
                    if #available(macOS 26, *) {
                        shape
                            .fill(SpaceTheme.gradient(for: space).opacity(0))
                            .glassEffect(.regular, in: shape)
                    } else {
                        shape
                            .fill(SpaceTheme.gradient(for: space).opacity(0))
                            .overlay(.ultraThinMaterial)
                            .clipShape(shape)
                    }
                }
                .padding(contentInset)
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
                RoundedRectangle(cornerRadius: contentCornerRadius, style: .continuous)
            )
        }
    }

    /// The tabs whose surfaces stay mounted for this window: the selected one
    /// (so it is built on first show), plus live tabs of every Space this window
    /// has shown — so neither a tab switch nor a Space switch detaches them.
    ///
    /// A tab with no live view is deliberately skipped, so mounting never builds
    /// a view the pool did not already keep — the existing capacity cap still
    /// governs memory, and lazy/restored-but-unopened tabs stay lazy. A Space
    /// another window is showing is left to that window, since one `NSView` has
    /// one superview.
    private var mountedTabs: [ChordCore.Tab] {
        let selectedID = windowState.selectedTabID
        var spaces = windowState.visitedSpaceIDs
        if let active = store.activeSpace(in: windowState)?.id { spaces.insert(active) }
        return store.tabs.filter { tab in
            if tab.id == selectedID { return true }
            guard spaces.contains(tab.spaceID),
                  tab.panes.allSatisfy({ store.hasLiveView(paneID: $0.id) })
            else { return false }
            return !store.spaceActiveInOtherWindow(tab.spaceID, than: windowState)
        }
    }
}
