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
    var openCommandBar: (CommandBarMode) -> Void = { _ in }

    /// While a tab is being dragged, the row slot the ephemeral list would drop
    /// it into (4.1). Nil at rest and whenever the pointer is not over the list.
    @State private var ephemeralDropIndex: Int?

    /// One row plus the `LazyVStack`'s inter-row spacing — the height of a slot
    /// the drop maps a cursor Y onto.
    private var rowSlot: CGFloat { Metrics.sidebarRowHeight + 2 }

    private var isDragging: Bool { store.draggingTabID != nil }

    var body: some View {
        VStack(spacing: 0) {
            header

            NavigationBar(store: store, downloads: downloads)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            // §4.1's sections, in order. The pinned grid is skipped entirely
            // when empty rather than left as a gap — an empty grid in a fresh
            // Space reads as something failing to load. During a drag an empty
            // section still shows a drop zone, so the first favourite can be
            // made by dragging.
            if !store.pinnedTabs.isEmpty {
                PinnedGrid(store: store)
                    .overlay { if isDragging { pinnedDropOverlay } }
            } else if isDragging {
                firstPinDropZone
            }

            newTabButton

            ephemeralList

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
            // While a swipe is in flight it blends toward the neighbour's stops
            // (4.2); at rest it uses the cached per-Space gradient so an idle
            // sidebar does not rebuild one every frame (6.4).
            if let space = store.activeSpace {
                gradient(for: space)
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

    // MARK: - Ephemeral list and drops

    /// The ephemeral tabs, with a drag *destination* laid over them during a
    /// drag (4.1). The destination reorders within the section, and accepts a
    /// pinned tab dropped in — which unpins it.
    private var ephemeralList: some View {
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
        .overlay(alignment: .top) {
            if isDragging {
                ZStack(alignment: .top) {
                    insertionIndicator
                    SidebarDropTarget(
                        onExit: { ephemeralDropIndex = nil },
                        onUpdate: { point in
                            ephemeralDropIndex = insertionIndex(forY: point.y)
                        },
                        onDrop: { tabID, point in
                            store.reorderTab(
                                tabID, toPinned: false, at: insertionIndex(forY: point.y)
                            )
                            ephemeralDropIndex = nil
                        }
                    )
                }
            }
        }
    }

    /// A line between rows marking where a drop would land.
    @ViewBuilder
    private var insertionIndicator: some View {
        if let index = ephemeralDropIndex {
            Capsule()
                .fill(SpaceTheme.accent(for: store.activeSpace ?? Space.makeDefault()))
                .frame(height: 2)
                .padding(.horizontal, 10)
                .offset(y: CGFloat(index) * rowSlot)
                .allowsHitTesting(false)
        }
    }

    /// Maps a cursor Y (top-left) onto the slot it is nearest the gap of, so a
    /// drop lands between rows rather than on one.
    private func insertionIndex(forY y: CGFloat) -> Int {
        let raw = Int(((y + rowSlot / 2) / rowSlot).rounded(.down))
        return max(0, min(raw, store.unpinnedTabs.count))
    }

    /// Dropping onto the favourites grid pins the tab (4.1). Appends rather than
    /// placing at a grid cell — the grid has no obvious linear slot to aim for,
    /// and the last position is the predictable one.
    private var pinnedDropOverlay: some View {
        SidebarDropTarget(
            onDrop: { tabID, _ in
                store.reorderTab(tabID, toPinned: true, at: store.pinnedTabs.count)
            }
        )
    }

    /// Shown in place of the (absent) grid while dragging, so the first
    /// favourite in a Space can be made by dragging a tab up.
    private var firstPinDropZone: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4]))
            .frame(height: Metrics.pinnedTileHeight)
            .overlay {
                Label("Pin to Favourites", systemImage: "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .overlay { pinnedDropOverlay }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
    }

    private func gradient(for space: BrowserCore.Space) -> LinearGradient {
        store.spaceSwipeProgress == 0
            ? SpaceTheme.gradient(for: space)
            : SpaceTheme.gradient(stops: store.swipeBlendedGradient)
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

    /// Opens the command bar rather than a blank tab, exactly as `Cmd+T` does
    /// (4.4). A new tab is one Return away, and you almost always wanted a
    /// destination rather than an empty page.
    private var newTabButton: some View {
        Button {
            openCommandBar(.newTab)
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
