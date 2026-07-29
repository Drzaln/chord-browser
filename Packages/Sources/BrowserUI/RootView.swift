import BrowserExtensions
import BrowserStore
import SwiftUI

public struct RootView: View {
    @Bindable private var store: TabStore
    /// This window's own view state — sidebar, sheets. Shared `TabStore`, one
    /// of these per window.
    @Bindable private var windowState: WindowState
    @Bindable private var downloads: DownloadsStore
    /// The extension host, present only when the extensions flag is on (M7,
    /// 7.5b). Threaded to the sidebar header for the toolbar-action buttons.
    private let extensionHost: (any ExtensionHost)?
    /// The extension install/enable/remove coordinator, present only when the
    /// subsystem is wired. Threaded to the settings sheet's Extensions section.
    private let extensions: ExtensionsService?
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
        windowState: WindowState,
        downloads: DownloadsStore,
        extensionHost: (any ExtensionHost)? = nil,
        extensions: ExtensionsService? = nil,
        openCommandBar: @escaping (CommandBarMode, String?) -> Void = { _, _ in }
    ) {
        self.store = store
        self.windowState = windowState
        self.downloads = downloads
        self.extensionHost = extensionHost
        self.extensions = extensions
        self.openCommandBar = openCommandBar
    }

    /// Collapsed and not currently revealed: the sidebar is not on screen at
    /// all. Collapsing hides it completely rather than leaving a rail, which is
    /// what Arc does and what makes the reveal worth having.
    private var isHidden: Bool {
        windowState.isPresentationMode || (windowState.isSidebarCollapsed && !isRevealed)
    }

    /// The macOS window title. Hidden visually by `.hiddenTitleBar`, but it is
    /// still the string the screen-share picker and Mission Control show — so a
    /// user hunting for this window among a grid can find it. Tracks the active
    /// tab's page title.
    private var windowTitle: String {
        let title = store.selectedTab(in: windowState)?.focusedPane.displayTitle ?? ""
        return title.isEmpty ? "Chord" : "Chord — \(title)"
    }

    /// The pane the window is currently showing, when it is screen-sharing —
    /// drives the "you are sharing" banner. WebKit surfaces no screen-capture
    /// signal, so this is observed in-page; see `ScreenShareMonitor`.
    private var sharingPaneID: UUID? {
        guard let paneID = store.selectedTab(in: windowState)?.focusedPaneID,
              store.runtime(for: paneID).isScreenSharing
        else { return nil }
        return paneID
    }

    /// Hide the traffic lights only while the sidebar is off screen *and* the
    /// window is not fullscreen. In fullscreen they must remain — hiding them
    /// leaves no way to exit but the keyboard, which is the bug this guards
    /// against.
    /// Something is keeping the revealed sidebar on screen: a resize drag in
    /// progress, or a Space sheet open over it. Hiding it out from under any of
    /// these takes the thing the user is using with it.
    private var isSidebarHeldOpen: Bool {
        windowState.isSidebarResizing
            || windowState.editingSpaceID != nil
            || windowState.deletingSpaceID != nil
    }

    private var shouldHideTrafficLights: Bool {
        // Presentation mode hides the sidebar but keeps the traffic lights, so
        // the user always has a visible way out of a mode meant for sharing.
        isHidden && !isFullscreen && !windowState.isPresentationMode
    }

    /// What the sidebar reserves in the layout, which is not what it draws.
    /// A revealed sidebar overhangs the page rather than pushing it — 4.1 is
    /// explicit that revealing must not shift web content, and shifting it
    /// would relayout every web view for as long as the pointer sat there.
    private var laneWidth: CGFloat {
        windowState.isSidebarCollapsed ? 0 : windowState.sidebarWidth
    }

    /// The x below which a swipe is over the sidebar and may switch Spaces (4.2).
    /// Zero while the sidebar is hidden, so the gesture is off then. A floating
    /// (revealed) sidebar is inset by `contentInset`, so its right edge sits that
    /// much further right. This is what keeps the Space swipe from stealing the
    /// web view's back/forward gesture.
    private var sidebarEngageWidth: CGFloat {
        guard !isHidden else { return 0 }
        return windowState.sidebarWidth + (windowState.isSidebarCollapsed ? Metrics.contentInset : 0)
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: laneWidth)
                WebContentCard(store: store, windowState: windowState)
            }

            // Only while hidden. A permanent strip is not needed once the
            // sidebar is on screen, and the sidebar's own hover handles
            // leaving. Presentation mode suppresses it too — the point of that
            // mode is that a shared window shows content and nothing else.
            if isHidden && !windowState.isPresentationMode {
                SidebarRevealStrip { reveal() }
                    .frame(width: SidebarRevealStrip.width)
                    .frame(maxHeight: .infinity)
                    .zIndex(2)
            }

            if let sharingPaneID {
                ScreenShareBanner {
                    store.stopScreenSharing(in: windowState)
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .center)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(3)
                .id(sharingPaneID)
            }

            if !isHidden {
                SidebarView(
                    store: store,
                    windowState: windowState,
                    downloads: downloads,
                    isFloating: windowState.isSidebarCollapsed,
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
        // How the menu bar reaches *this* window's state — Cmd+S, Cmd+, and
        // Cmd+Y act on whichever window is focused. See `FocusedWindowState`.
        .focusedSceneValue(\.windowState, windowState)
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
            configureWindow()
            // Associate this window with its state so Little Arc promotion can
            // bring *this* window forward, and treat a window that appears while
            // key as focused (the first window at launch).
            if let window {
                WindowRegistry.associate(windowState, with: window)
                if window.isKeyWindow { store.windowDidBecomeFocused(windowState) }
            }
        }
        // Track which window is the user's current one, so app-opened URLs and a
        // promoted Little Arc tab land here rather than always in the primary.
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
        ) { note in
            guard let keyed = note.object as? NSWindow, keyed === window else { return }
            WindowRegistry.associate(windowState, with: keyed)
            store.windowDidBecomeFocused(windowState)
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
        // Keep the (visually hidden) window title in step with the page — it is
        // what the screen-share picker and Mission Control label this window by.
        .onChange(of: windowTitle, initial: true) { _, title in
            window?.title = title
        }
        .onChange(of: windowState.isSidebarCollapsed) { _, collapsed in
            // Showing the sidebar by menu while the pointer sits at the edge
            // would otherwise leave the reveal flag set, and the sidebar would
            // hide itself the moment the pointer moved away.
            if !collapsed { cancelPendingHide(); isRevealed = false }
        }
        // One rule, not three: a revealed sidebar stays put while anything is
        // holding it open, and gets its hide timer back the moment nothing is.
        .onChange(of: isSidebarHeldOpen) { _, held in
            if !held && !isSidebarHovered { scheduleHide() }
        }
        // All of them presented here rather than in the sidebar so they survive
        // the sidebar collapsing (and auto-hiding) beneath them. Factored into
        // their own modifier because inlining them puts `body` past what the
        // type-checker will solve in reasonable time.
        .modifier(
            RootSheets(store: store, windowState: windowState, extensions: extensions)
        )
        .onAppear {
            let monitor = SpaceSwipeMonitor(store: store, windowState: windowState)
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

    /// The Space-tinted window background — the frosted-glass frame around the
    /// web card. A `.ultraThinMaterial` base (which, with the window non-opaque,
    /// samples and blurs the desktop behind it) tinted by the per-Space gradient,
    /// blended during a swipe. Degrades to plain glass when there is no Space.
    @ViewBuilder
    private var spaceBorderTint: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            if let space = store.activeSpace(in: windowState) {
                Group {
                    if windowState.spaceSwipeProgress == 0 {
                        SpaceTheme.gradient(for: space)
                    } else {
                        SpaceTheme.gradient(stops: store.swipeBlendedGradient(in: windowState))
                    }
                }
                .opacity(0.4)
            }
        }
    }

    /// Makes the window non-opaque so the frosted-glass materials (sidebar +
    /// border) sample and blur the desktop behind the window rather than a flat
    /// fill. The web content card stays opaque, so pages are unaffected.
    /// Idempotent — safe to call whenever the window reference resolves.
    private func configureWindow() {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        // Seed the title as soon as the window resolves; the observer keeps it
        // current after that.
        window.title = windowTitle
    }

    private func reveal() {
        cancelPendingHide()
        guard windowState.isSidebarCollapsed else { return }
        isRevealed = true
    }

    /// Delayed, and cancellable. Hiding the instant the pointer crosses the
    /// sidebar's edge makes it snap shut while you are travelling towards a
    /// row near that edge.
    private func scheduleHide() {
        cancelPendingHide()
        guard isRevealed else { return }
        guard !isSidebarHeldOpen else { return }
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

