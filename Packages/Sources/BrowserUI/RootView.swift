import BrowserExtensions
import BrowserStore
import SwiftUI

public struct RootView: View {
    @Bindable private var store: TabStore
    @Bindable private var downloads: DownloadsStore
    /// The extension host, present only when the extensions flag is on (M7,
    /// 7.5b). Threaded to the sidebar header for the toolbar-action buttons.
    private let extensionHost: (any ExtensionHost)?
    /// Opens the command bar, optionally pre-filled with a query. Injected
    /// because the controller is owned by the app delegate — the panel outlives
    /// any view, and Store must not depend on UI to reach it.
    private let openCommandBar: (CommandBarMode, String?) -> Void

    /// The sidebar is hidden but the pointer has reached the left edge, so it
    /// is showing on top of the page (4.1).
    @State private var isRevealed = false
    @State private var isSidebarHovered = false
    @State private var collapseTask: Task<Void, Never>?
    @State private var window: NSWindow?
    /// Native fullscreen. The traffic lights must stay put there even with the
    /// sidebar collapsed — they are the only way out, and in fullscreen AppKit
    /// shows them in the auto-revealing top overlay, not over the page.
    @State private var isFullscreen = false
    /// The two-finger Space-switch swipe (4.2). Held here so its local event
    /// monitor lives exactly as long as the view is on screen.
    @State private var swipeMonitor: SpaceSwipeMonitor?
    /// Double-click the top strip to zoom, lost when the card was extended over
    /// the titlebar. Same lifecycle as the swipe monitor.
    @State private var titlebarMonitor: TitlebarDoubleClickMonitor?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        store: TabStore,
        downloads: DownloadsStore,
        extensionHost: (any ExtensionHost)? = nil,
        openCommandBar: @escaping (CommandBarMode, String?) -> Void = { _, _ in }
    ) {
        self.store = store
        self.downloads = downloads
        self.extensionHost = extensionHost
        self.openCommandBar = openCommandBar
    }

    /// Collapsed and not currently revealed: the sidebar is not on screen at
    /// all. Collapsing hides it completely rather than leaving a rail, which is
    /// what Arc does and what makes the reveal worth having.
    private var isHidden: Bool {
        store.isSidebarCollapsed && !isRevealed
    }

    /// Hide the traffic lights only while the sidebar is off screen *and* the
    /// window is not fullscreen. In fullscreen they must remain — hiding them
    /// leaves no way to exit but the keyboard, which is the bug this guards
    /// against.
    private var shouldHideTrafficLights: Bool {
        isHidden && !isFullscreen
    }

    /// What the sidebar reserves in the layout, which is not what it draws.
    /// A revealed sidebar overhangs the page rather than pushing it — 4.1 is
    /// explicit that revealing must not shift web content, and shifting it
    /// would relayout every web view for as long as the pointer sat there.
    private var laneWidth: CGFloat {
        store.isSidebarCollapsed ? 0 : store.sidebarWidth
    }

    /// The x below which a swipe is over the sidebar and may switch Spaces (4.2).
    /// Zero while the sidebar is hidden, so the gesture is off then. A floating
    /// (revealed) sidebar is inset by `contentInset`, so its right edge sits that
    /// much further right. This is what keeps the Space swipe from stealing the
    /// web view's back/forward gesture.
    private var sidebarEngageWidth: CGFloat {
        guard !isHidden else { return 0 }
        return store.sidebarWidth + (store.isSidebarCollapsed ? Metrics.contentInset : 0)
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
                    openCommandBar: openCommandBar,
                    extensionHost: extensionHost
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
                    isSidebarHovered = isInside
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
        .onChange(of: shouldHideTrafficLights, initial: true) { _, hide in
            window?.setTrafficLightsHidden(hide)
        }
        .onChange(of: window == nil) { _, _ in
            window?.setTrafficLightsHidden(shouldHideTrafficLights)
        }
        // Fullscreen enter/exit must re-evaluate the traffic lights: entering
        // with the sidebar collapsed would otherwise leave them hidden and the
        // window inescapable but by keyboard.
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)
        ) { _ in isFullscreen = true }
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)
        ) { _ in isFullscreen = false }
        .onChange(of: store.isSidebarCollapsed) { _, collapsed in
            // Showing the sidebar by menu while the pointer sits at the edge
            // would otherwise leave the reveal flag set, and the sidebar would
            // hide itself the moment the pointer moved away.
            if !collapsed { cancelPendingHide(); isRevealed = false }
        }
        .onChange(of: store.isSidebarResizing) { _, resizing in
            if !resizing && !isSidebarHovered {
                scheduleHide()
            }
        }
        .onChange(of: store.deletingSpaceID) { _, deletingID in
            if deletingID == nil && !isSidebarHovered {
                scheduleHide()
            }
        }
        .onChange(of: store.editingSpaceID) { _, editingID in
            if editingID == nil && !isSidebarHovered {
                scheduleHide()
            }
        }
        // Presented here rather than in the sidebar so it survives the sidebar
        // collapsing (and auto-hiding) beneath it — the bug being fixed.
        .sheet(item: Binding(
            get: { store.spaces.first { $0.id == store.editingSpaceID } },
            set: { if $0 == nil { store.editingSpaceID = nil } }
        )) { space in
            SpaceEditor(store: store, space: space)
        }
        // Extension permission prompts, one at a time (7.5c). A dismiss without
        // a decision (Esc / swipe) is treated as a denial by the setter.
        .sheet(item: Binding(
            get: { store.pendingPermissionRequests.first },
            set: { newValue in
                if newValue == nil, let current = store.pendingPermissionRequests.first {
                    store.resolvePermissionRequest(current.id, allow: false)
                }
            }
        )) { request in
            ExtensionPermissionSheet(request: request, store: store)
        }
        .confirmationDialog(
            "Delete “\(store.spaces.first { $0.id == store.deletingSpaceID }?.name ?? "")”?",
            isPresented: Binding(
                get: { store.deletingSpaceID != nil },
                set: { if !$0 { store.deletingSpaceID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Space and Its Data", role: .destructive) {
                guard let spaceID = store.deletingSpaceID else { return }
                store.deletingSpaceID = nil
                Task { await store.deleteSpace(spaceID) }
            }
            Button("Cancel", role: .cancel) { store.deletingSpaceID = nil }
        } message: {
            // 3.3: reclaiming the data store is irreversible, so say so plainly.
            Text("Its tabs, cookies, and cached data are removed permanently.")
        }
        .task { await store.restore() }
        .onAppear {
            let monitor = SpaceSwipeMonitor(store: store)
            monitor.engageMaxX = sidebarEngageWidth
            monitor.window = window
            monitor.start()
            swipeMonitor = monitor

            let titlebar = TitlebarDoubleClickMonitor()
            titlebar.window = window
            titlebar.start()
            titlebarMonitor = titlebar
        }
        .onDisappear {
            swipeMonitor?.stop()
            swipeMonitor = nil
            titlebarMonitor?.stop()
            titlebarMonitor = nil
        }
        // Keep the swipe gesture scoped to the sidebar as its width and
        // visibility change, and hand both monitors the window once it exists.
        .onChange(of: sidebarEngageWidth) { _, width in
            swipeMonitor?.engageMaxX = width
        }
        .onChange(of: window == nil) { _, _ in
            swipeMonitor?.window = window
            titlebarMonitor?.window = window
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
        guard !store.isSidebarResizing else { return }
        guard store.editingSpaceID == nil else { return }
        guard store.deletingSpaceID == nil else { return }
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
