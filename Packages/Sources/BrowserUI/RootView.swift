import BrowserStore
import SwiftUI

public struct RootView: View {
    @Bindable private var store: TabStore
    @Bindable private var downloads: DownloadsStore

    /// The pointer is over the collapsed rail, so it is showing full width on
    /// top of the page (4.1).
    @State private var isHoverExpanded = false
    @State private var collapseTask: Task<Void, Never>?
    @State private var window: NSWindow?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(store: TabStore, downloads: DownloadsStore) {
        self.store = store
        self.downloads = downloads
    }

    /// Collapsed *and* not being hovered. The rail is the only state that
    /// draws icons alone.
    private var showsRail: Bool {
        store.isSidebarCollapsed && !isHoverExpanded
    }

    /// What the sidebar reserves in the layout, which is not what it draws.
    /// A hover-expanded sidebar overhangs the page rather than pushing it —
    /// 4.1 is explicit that hovering must not shift web content, and shifting
    /// it would also relayout every web view for the length of a hover.
    private var laneWidth: CGFloat {
        store.isSidebarCollapsed ? Metrics.sidebarCollapsedWidth : Metrics.sidebarWidth
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: laneWidth)
                WebContentCard(store: store)
            }

            SidebarView(store: store, downloads: downloads, isCollapsed: showsRail)
                // Only while overhanging the page. A shadow under the sidebar
                // in its own lane reads as a seam down the middle of the window.
                .shadow(
                    color: .black.opacity(isHoverExpanded ? Metrics.shadowOpacity : 0),
                    radius: Metrics.shadowRadius,
                    x: 2
                )
                .onHover { isInside in
                    if isInside { expandOnHover() } else { scheduleCollapse() }
                }
                .zIndex(1)
        }
        // `.hiddenTitleBar` still reserves the titlebar strip across the whole
        // window, which pushed the web card down and left a dead band above it.
        // The card runs to the top edge instead; the sidebar reserves its own
        // clearance for the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 720, minHeight: 480)
        .background(.background)
        .background {
            WindowAccessor { window = $0 }
        }
        // The traffic lights do not fit a 48-point rail — see `TrafficLights`.
        .onChange(of: showsRail, initial: true) { _, rail in
            window?.setTrafficLightsHidden(rail)
        }
        .onChange(of: window == nil) { _, _ in
            window?.setTrafficLightsHidden(showsRail)
        }
        .animation(
            Motion.respectingReduceMotion(Motion.sidebarCollapse, reduceMotion: reduceMotion),
            value: showsRail
        )
        .onChange(of: store.isSidebarCollapsed) { _, collapsed in
            // Expanding by menu while the pointer sits over the rail would
            // otherwise leave the hover flag set, and the sidebar would
            // collapse itself the moment the pointer left.
            if !collapsed { cancelPendingCollapse(); isHoverExpanded = false }
        }
        .task {
            await store.restore()
        }
    }

    private func expandOnHover() {
        cancelPendingCollapse()
        guard store.isSidebarCollapsed else { return }
        isHoverExpanded = true
    }

    /// Delayed, and cancellable. Collapsing the instant the pointer leaves
    /// makes the sidebar snap shut while you are travelling from a row to the
    /// page, and re-entering during the delay must call the whole thing off.
    private func scheduleCollapse() {
        cancelPendingCollapse()
        guard isHoverExpanded else { return }
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: Motion.sidebarCollapseDelay)
            guard !Task.isCancelled else { return }
            isHoverExpanded = false
        }
    }

    private func cancelPendingCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }
}
