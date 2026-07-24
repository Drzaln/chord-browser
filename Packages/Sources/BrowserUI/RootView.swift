import BrowserStore
import SwiftUI

public struct RootView: View {
    @Bindable private var store: TabStore
    @Bindable private var downloads: DownloadsStore
    /// Opens the command bar. Injected because the controller is owned by the
    /// app delegate — the panel outlives any view, and Store must not depend
    /// on UI to reach it.
    private let openCommandBar: (CommandBarMode) -> Void

    /// The sidebar is hidden but the pointer has reached the left edge, so it
    /// is showing on top of the page (4.1).
    @State private var isRevealed = false
    @State private var collapseTask: Task<Void, Never>?
    @State private var window: NSWindow?
    /// The two-finger Space-switch swipe (4.2). Held here so its local event
    /// monitor lives exactly as long as the view is on screen.
    @State private var swipeMonitor: SpaceSwipeMonitor?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        store: TabStore,
        downloads: DownloadsStore,
        openCommandBar: @escaping (CommandBarMode) -> Void = { _ in }
    ) {
        self.store = store
        self.downloads = downloads
        self.openCommandBar = openCommandBar
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

    /// The x below which a swipe is over the sidebar and may switch Spaces (4.2).
    /// Zero while the sidebar is hidden, so the gesture is off then. A floating
    /// (revealed) sidebar is inset by `contentInset`, so its right edge sits that
    /// much further right. This is what keeps the Space swipe from stealing the
    /// web view's back/forward gesture.
    private var sidebarEngageWidth: CGFloat {
        guard !isHidden else { return 0 }
        return Metrics.sidebarWidth + (store.isSidebarCollapsed ? Metrics.contentInset : 0)
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
                    store: store,
                    downloads: downloads,
                    isFloating: store.isSidebarCollapsed,
                    openCommandBar: openCommandBar
                )
                // Slides in from off-screen rather than fading: the sidebar is
                // arriving from the edge the pointer just touched, and saying
                // so is most of what makes the reveal feel like Arc's. Under
                // Reduce Motion it fades instead — the point of the setting is
                // to drop travel, which speeding the slide alone does not.
                .transition(reduceMotion ? .opacity : .move(edge: .leading))
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
        // The active Space's colour tints the window, which shows as the border
        // around the inset content card (and follows a swipe's blend). The card
        // itself is opaque, so the tint reads only in the inset — the coloured
        // frame around the page, not under it. `.ignoresSafeArea()` so it reaches
        // the top edge too: without it the tint stops at the titlebar safe-area
        // line and the card's top inset shows raw window chrome, leaving every
        // edge but the top coloured.
        .background { spaceBorderTint.ignoresSafeArea() }
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
        .onAppear {
            let monitor = SpaceSwipeMonitor(store: store)
            monitor.engageMaxX = sidebarEngageWidth
            monitor.window = window
            monitor.start()
            swipeMonitor = monitor
        }
        .onDisappear {
            swipeMonitor?.stop()
            swipeMonitor = nil
        }
        // Keep the swipe gesture scoped to the sidebar as its width and
        // visibility change, and once the window exists.
        .onChange(of: sidebarEngageWidth) { _, width in
            swipeMonitor?.engageMaxX = width
        }
        .onChange(of: window == nil) { _, _ in
            swipeMonitor?.window = window
        }
    }

    /// The Space-tinted window background. Uses the cached per-Space gradient at
    /// rest and the blended one during a swipe, over the system window colour so
    /// it degrades to plain chrome when there is no Space.
    @ViewBuilder
    private var spaceBorderTint: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let space = store.activeSpace {
                Group {
                    if store.spaceSwipeProgress == 0 {
                        SpaceTheme.gradient(for: space)
                    } else {
                        SpaceTheme.gradient(stops: store.swipeBlendedGradient)
                    }
                }
                .opacity(0.55)
            }
        }
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
