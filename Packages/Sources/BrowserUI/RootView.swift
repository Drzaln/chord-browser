import BrowserStore
import SwiftUI

public struct RootView: View {
    @Bindable private var store: TabStore
    @Bindable private var downloads: DownloadsStore

    /// The sidebar is hidden but the pointer has reached the left edge, so it
    /// is showing on top of the page (4.1).
    @State private var isRevealed = false
    @State private var collapseTask: Task<Void, Never>?
    @State private var window: NSWindow?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(store: TabStore, downloads: DownloadsStore) {
        self.store = store
        self.downloads = downloads
    }

    /// Collapsed and not currently revealed: the sidebar is not on screen at
    /// all. Collapsing hides it completely rather than leaving a rail, which is
    /// what Arc does and what makes the reveal worth having.
    private var isHidden: Bool {
        store.isSidebarCollapsed && !isRevealed
    }

    /// What the sidebar reserves in the layout, which is not what it draws.
    /// A revealed sidebar overhangs the page rather than pushing it — 4.1 is
    /// explicit that revealing must not shift web content, and shifting it
    /// would relayout every web view for as long as the pointer sat there.
    private var laneWidth: CGFloat {
        store.isSidebarCollapsed ? 0 : Metrics.sidebarWidth
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: laneWidth)
                WebContentCard(store: store)
            }

            // Only while hidden. A permanent strip is not needed once the
            // sidebar is on screen, and the sidebar's own hover handles
            // leaving.
            if isHidden {
                SidebarRevealStrip { reveal() }
                    .frame(width: SidebarRevealStrip.width)
                    .frame(maxHeight: .infinity)
                    .zIndex(2)
            }

            if !isHidden {
                SidebarView(
                    store: store, downloads: downloads, isFloating: store.isSidebarCollapsed
                )
                // Slides in from off-screen rather than fading: the sidebar is
                // arriving from the edge the pointer just touched, and saying
                // so is most of what makes the reveal feel like Arc's.
                .transition(.move(edge: .leading))
                // Leaving the sidebar is an ordinary hover exit — the view is
                // on screen by then, so no tracking strip is involved.
                .onHover { isInside in
                    if isInside { cancelPendingHide() } else { scheduleHide() }
                }
                .zIndex(1)
            }
        }
        // `.hiddenTitleBar` still reserves the titlebar strip across the whole
        // window, which pushed the web card down and left a dead band above it.
        // The card runs to the top edge instead; the sidebar reserves its own
        // clearance for the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 720, minHeight: 480)
        .background(.background)
        .background { WindowAccessor { window = $0 } }
        .animation(
            Motion.respectingReduceMotion(Motion.sidebarCollapse, reduceMotion: reduceMotion),
            value: isHidden
        )
        // The traffic lights sit at a fixed offset from the window's top-left
        // whatever is under them, so with no sidebar there they land on the
        // page — see `TrafficLights`.
        .onChange(of: isHidden, initial: true) { _, hidden in
            window?.setTrafficLightsHidden(hidden)
        }
        .onChange(of: window == nil) { _, _ in
            window?.setTrafficLightsHidden(isHidden)
        }
        .onChange(of: store.isSidebarCollapsed) { _, collapsed in
            // Showing the sidebar by menu while the pointer sits at the edge
            // would otherwise leave the reveal flag set, and the sidebar would
            // hide itself the moment the pointer moved away.
            if !collapsed { cancelPendingHide(); isRevealed = false }
        }
        .task { await store.restore() }
    }

    private func reveal() {
        cancelPendingHide()
        guard store.isSidebarCollapsed else { return }
        isRevealed = true
    }

    /// Delayed, and cancellable. Hiding the instant the pointer crosses the
    /// sidebar's edge makes it snap shut while you are travelling towards a
    /// row near that edge.
    private func scheduleHide() {
        cancelPendingHide()
        guard isRevealed else { return }
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: Motion.sidebarCollapseDelay)
            guard !Task.isCancelled else { return }
            isRevealed = false
        }
    }

    private func cancelPendingHide() {
        collapseTask?.cancel()
        collapseTask = nil
    }
}
