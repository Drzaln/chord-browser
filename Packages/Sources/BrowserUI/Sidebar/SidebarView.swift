import BrowserCore
import BrowserStore
import SwiftUI

/// The sidebar, in Arc's arrangement (4.1): Space switcher, address field,
/// pinned favourites, new-tab affordance, then the ephemeral tabs.
///
/// Rendered as a floating card when it is overhanging the page, and flush when
/// it owns its lane — which is what Arc does, and what makes the revealed
/// state read as *over* the content rather than part of it.
struct SidebarView: View {
    @Bindable var store: TabStore
    @Bindable var downloads: DownloadsStore
    /// Overhanging the page rather than sitting in its own lane.
    var isFloating: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header

            NavigationBar(store: store, downloads: downloads)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            // §4.1's sections, in order. The pinned grid is skipped entirely
            // when empty rather than left as a gap — an empty grid in a fresh
            // Space reads as something failing to load.
            if !store.pinnedTabs.isEmpty {
                PinnedGrid(store: store)
            }

            newTabButton

            // Lazy so a large tab list does not build every row up front (6.4).
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.unpinnedTabs) { tab in
                        TabRowView(
                            tab: tab,
                            isSelected: tab.id == store.selectedTabID,
                            select: { store.select(tab.id) },
                            close: { store.closeTab(tab.id) },
                            beginDrag: { store.beginTabDrag(tab.id) },
                            endDrag: { store.endTabDrag() }
                        )
                        .id(tab.id)  // stable identity, so rows are not rebuilt
                        .contextMenu { rowMenu(for: tab) }
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)

            // Arc keeps the Space switcher on the bottom bar, under the tab
            // list, rather than above it. §4.1 lists it first; the order there
            // is about which sections exist, and the bottom is where the
            // interaction model this is copying puts it.
            Divider().opacity(0.5)
            SpaceSwitcher(store: store)
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
        .clipShape(
            RoundedRectangle(
                cornerRadius: isFloating ? Metrics.contentCornerRadius : 0, style: .continuous
            )
        )
        .shadow(
            color: .black.opacity(isFloating ? Metrics.shadowOpacity * 1.6 : 0),
            radius: Metrics.shadowRadius,
            x: 2
        )
        .padding(isFloating ? Metrics.contentInset : 0)
    }

    /// Clears the traffic lights, and carries the collapse control beside them
    /// the way the rest of the platform does.
    private var header: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            collapseButton
        }
        .frame(height: Metrics.titlebarInset)
        .padding(.trailing, 8)
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
        .help("Hide Sidebar")
        .accessibilityLabel("Hide Sidebar")
        // No `.keyboardShortcut` here. A view-level one is handled in the
        // window's responder chain and silently beats the menu item with the
        // same key — that is how Cmd+T was stolen from the command bar in M3.
    }

    @ViewBuilder
    private func rowMenu(for tab: BrowserCore.Tab) -> some View {
        Button("Pin to Favourites") { store.setPinned(true, tabID: tab.id) }

        // Cross-Space drag-and-drop is still to come; the menu is the M2
        // affordance.
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
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        // No keyboard shortcut here on purpose — see `collapseButton`.
    }
}
