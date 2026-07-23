import BrowserCore
import BrowserStore
import SwiftUI

struct SidebarView: View {
    @Bindable var store: TabStore
    @Bindable var downloads: DownloadsStore
    /// Rendered as the icons-only rail (4.1). Distinct from
    /// `store.isSidebarCollapsed`: a collapsed sidebar under the pointer is
    /// expanded, and `RootView` owns that distinction.
    var isCollapsed: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Clears the traffic lights, which the window no longer reserves
            // space for. Sidebar only — the web content starts at the top edge.
            // Clears the traffic lights, and carries the collapse button beside
            // them the way the rest of the platform does. In the rail the
            // lights are hidden, so the button takes the space instead of
            // sharing it — otherwise the only way back is the menu.
            HStack(spacing: 0) {
                if !isCollapsed { Spacer(minLength: 0) }
                collapseButton
                    .frame(maxWidth: isCollapsed ? .infinity : nil)
            }
            .frame(height: Metrics.titlebarInset)
            .padding(.trailing, isCollapsed ? 0 : 8)

            SpaceSwitcher(store: store, isCollapsed: isCollapsed)

            // The address field and its buttons need width the rail does not
            // have. Hidden rather than shrunk: a 48-point text field is not a
            // smaller affordance, it is a broken one.
            if !isCollapsed {
                NavigationBar(store: store, downloads: downloads)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }

            // Lazy so a large tab list does not build every row up front (6.4).
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.visibleTabs) { tab in
                        TabRowView(
                            tab: tab,
                            isSelected: tab.id == store.selectedTabID,
                            isCollapsed: isCollapsed,
                            select: { store.select(tab.id) },
                            close: { store.closeTab(tab.id) },
                            beginDrag: { store.beginTabDrag(tab.id) },
                            endDrag: { store.endTabDrag() }
                        )
                        .id(tab.id)  // stable identity, so rows are not rebuilt
                        .contextMenu { moveMenu(for: tab) }
                    }
                }
                .padding(.horizontal, isCollapsed ? 6 : 8)
            }
            .scrollIndicators(isCollapsed ? .hidden : .automatic)

            newTabButton
        }
        .frame(width: isCollapsed ? Metrics.sidebarCollapsedWidth : Metrics.sidebarWidth)
        .background {
            // The active Space's gradient, under a material overlay (4.1).
            if let space = store.activeSpace {
                SpaceTheme.gradient(for: space)
                    .opacity(0.35)
                    .overlay(.regularMaterial)
            } else {
                Color.clear.overlay(.regularMaterial)
            }
        }
    }

    private var collapseButton: some View {
        Button {
            store.isSidebarCollapsed.toggle()
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(store.isSidebarCollapsed ? "Expand Sidebar" : "Collapse Sidebar")
        .accessibilityLabel(store.isSidebarCollapsed ? "Expand Sidebar" : "Collapse Sidebar")
        // No `.keyboardShortcut` here. A view-level one is handled in the
        // window's responder chain and silently beats the menu item with the
        // same key — that is how Cmd+T was stolen from the command bar in M3.
    }

    @ViewBuilder
    private func moveMenu(for tab: BrowserCore.Tab) -> some View {
        // Cross-Space drag-and-drop is M6; the menu is the M2 affordance.
        Menu("Move to Space") {
            ForEach(store.spaces.filter { $0.id != tab.spaceID }) { space in
                Button(space.name) { store.moveTab(tab.id, toSpace: space.id) }
            }
        }
        .disabled(store.spaces.count <= 1)
    }

    private var newTabButton: some View {
        Button {
            store.newTab()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(maxWidth: isCollapsed ? .infinity : nil)
                if !isCollapsed {
                    Text("New Tab")
                        .font(.system(size: 12))
                    Spacer()
                }
            }
            .padding(.horizontal, isCollapsed ? 0 : 8)
            .frame(height: Metrics.sidebarRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(8)
        .help(isCollapsed ? "New Tab" : "")
        // No keyboard shortcut here on purpose. A view-level `.keyboardShortcut`
        // is handled in the window's responder chain and beats the menu item of
        // the same key, so binding Cmd+T here silently stole it from the command
        // bar (4.4) and quietly opened tabs instead. Shortcuts live in
        // `BrowserCommands` only.
    }
}
