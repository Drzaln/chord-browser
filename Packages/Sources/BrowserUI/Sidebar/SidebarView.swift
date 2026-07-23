import BrowserCore
import BrowserStore
import SwiftUI

struct SidebarView: View {
    @Bindable var store: TabStore
    @Bindable var downloads: DownloadsStore

    var body: some View {
        VStack(spacing: 0) {
            // Clears the traffic lights, which the window no longer reserves
            // space for. Sidebar only — the web content starts at the top edge.
            Color.clear.frame(height: Metrics.titlebarInset)

            SpaceSwitcher(store: store)

            NavigationBar(store: store, downloads: downloads)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)

            // Lazy so a large tab list does not build every row up front (6.4).
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.visibleTabs) { tab in
                        TabRowView(
                            tab: tab,
                            isSelected: tab.id == store.selectedTabID,
                            select: { store.select(tab.id) },
                            close: { store.closeTab(tab.id) },
                            beginDrag: { store.beginTabDrag(tab.id) },
                            endDrag: { store.endTabDrag() }
                        )
                        .id(tab.id)  // stable identity, so rows are not rebuilt
                        .contextMenu { moveMenu(for: tab) }
                    }
                }
                .padding(.horizontal, 8)
            }

            newTabButton
        }
        .frame(width: Metrics.sidebarWidth)
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
                Text("New Tab")
                    .font(.system(size: 12))
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: Metrics.sidebarRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(8)
        // No keyboard shortcut here on purpose. A view-level `.keyboardShortcut`
        // is handled in the window's responder chain and beats the menu item of
        // the same key, so binding Cmd+T here silently stole it from the command
        // bar (4.4) and quietly opened tabs instead. Shortcuts live in
        // `BrowserCommands` only.
    }
}
