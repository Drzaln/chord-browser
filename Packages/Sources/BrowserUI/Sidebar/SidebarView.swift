import BrowserCore
import BrowserExtensions
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
    var openCommandBar: (CommandBarMode, String?) -> Void = { _, _ in }
    /// The extension host, present only when the extensions flag is on (M7,
    /// 7.5b). Drives the toolbar-action buttons in the header; `nil` means no
    /// extension UI at all, so the header is unchanged from before M7.
    var extensionHost: (any ExtensionHost)?

    /// The active Space's colour, used to tint the tab highlights and the
    /// address button so they read as part of the Space (items 1 and 4). Cheap
    /// to recompute — it is one colour off the cached gradient stops.
    private var spaceTint: Color {
        SpaceTheme.accent(for: store.activeSpace ?? Space.makeDefault())
    }

    /// While a tab is being dragged, the row slot the ephemeral list would drop
    /// it into (4.1). Nil at rest and whenever the pointer is not over the list.
    @State private var ephemeralDropIndex: Int?
    @State private var dragStartWidth: CGFloat?
    /// The folder whose name is being edited inline, if any.
    @State private var renamingFolderID: UUID?

    /// One row plus the `LazyVStack`'s inter-row spacing — the height of a slot
    /// the drop maps a cursor Y onto.
    private var rowSlot: CGFloat { Metrics.sidebarRowHeight + 2 }

    private var isDragging: Bool { store.draggingTabID != nil }

    var body: some View {
        VStack(spacing: 0) {
            header

            NavigationBar(
                store: store, downloads: downloads,
                tint: spaceTint, openCommandBar: openCommandBar
            )
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
        .frame(width: store.sidebarWidth)
        .background {
            // The active Space's gradient, under a material overlay (4.1).
            // While a swipe is in flight it blends toward the neighbour's stops
            // (4.2); at rest it uses the cached per-Space gradient so an idle
            // sidebar does not rebuild one every frame (6.4).
            // Frosted glass in both modes: `.ultraThinMaterial` over the Space
            // gradient. Floating uses a lower tint so the page reads through it;
            // docked keeps more tint so the Space colour still carries, but the
            // material is the same thin glass either way (the window is
            // non-opaque, so the material samples the desktop behind it).
            if let space = store.activeSpace {
                gradient(for: space)
                    .opacity(isFloating ? 0.1 : 0.28)
                    .overlay(.ultraThinMaterial)
            } else {
                Color.clear.overlay(.ultraThinMaterial)
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
        // Inset the floating card on three sides but not the top: the traffic
        // lights sit at the window's top edge, so an 8-point top inset put the
        // header — and its collapse button — that much lower than them. Running
        // the card to the top edge lines the collapse button up with the lights.
        //.padding(.leading, isFloating ? Metrics.contentInset : 0)
        //.padding(.bottom, isFloating ? Metrics.contentInset : 0)
        //.padding(.trailing, isFloating ? Metrics.contentInset : 0)
        .overlay(alignment: .trailing) {
            Color.clear
                .frame(width: 6)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            if dragStartWidth == nil {
                                dragStartWidth = store.sidebarWidth
                                store.isSidebarResizing = true
                            }
                            if let startWidth = dragStartWidth {
                                let newWidth = startWidth + value.translation.width
                                store.sidebarWidth = min(max(newWidth, 160), 400)
                            }
                        }
                        .onEnded { _ in
                            dragStartWidth = nil
                            store.isSidebarResizing = false
                        }
                )
        }
    }

    // MARK: - Ephemeral list and drops

    /// The ephemeral tabs, with a drag *destination* laid over them during a
    /// drag (4.1). The destination reorders within the section, and accepts a
    /// pinned tab dropped in — which unpins it.
    private var ephemeralList: some View {
        // Lazy so a large tab list does not build every row up front (6.4).
        ScrollView {
            LazyVStack(spacing: 2) {
                foldersSection

                ForEach(store.unpinnedTabs) { tab in
                    TabRowView(
                        tab: tab,
                        isSelected: tab.id == store.selectedTabID,
                        tint: spaceTint,
                        isPlayingAudio: store.runtime(for: tab.focusedPaneID).isPlayingAudio,
                        isMuted: store.runtime(for: tab.focusedPaneID).isMuted,
                        select: { store.select(tab.id) },
                        close: { store.closeTab(tab.id) },
                        toggleMute: { store.toggleMute(tab.id) },
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
            if let extensionHost {
                ExtensionActionsBar(store: store, host: extensionHost)
                    .padding(.trailing, 4)
            }
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

    // MARK: - Folders

    /// The active Space's folders, each a collapsible header with its tabs
    /// nested beneath (non-spec: user-requested).
    @ViewBuilder
    private var foldersSection: some View {
        ForEach(store.activeSpaceFolders) { folder in
            FolderRowView(
                folder: folder,
                isRenaming: renamingFolderID == folder.id,
                toggleCollapsed: { store.toggleFolderCollapsed(folder.id) },
                rename: { store.renameFolder(folder.id, to: $0); renamingFolderID = nil },
                beginRename: { renamingFolderID = folder.id },
                delete: { store.deleteFolder(folder.id) }
            )

            if !folder.isCollapsed {
                ForEach(store.tabs(inFolder: folder.id)) { tab in
                    TabRowView(
                        tab: tab,
                        isSelected: tab.id == store.selectedTabID,
                        tint: spaceTint,
                        isPlayingAudio: store.runtime(for: tab.focusedPaneID).isPlayingAudio,
                        isMuted: store.runtime(for: tab.focusedPaneID).isMuted,
                        select: { store.select(tab.id) },
                        close: { store.closeTab(tab.id) },
                        toggleMute: { store.toggleMute(tab.id) },
                        beginDrag: { store.beginTabDrag(tab.id) },
                        endDrag: { store.endTabDrag() }
                    )
                    .padding(.leading, 14)  // nested under the folder
                    .id(tab.id)
                    .contextMenu { rowMenu(for: tab) }
                }
            }
        }
    }

    @ViewBuilder
    private func rowMenu(for tab: BrowserCore.Tab) -> some View {
        Button("Pin to Favourites") { store.setPinned(true, tabID: tab.id) }

        Button(store.isMuted(tab.id) ? "Unmute Tab" : "Mute Tab") {
            store.toggleMute(tab.id)
        }

        // Move to / out of a folder (non-spec: user-requested).
        Menu("Move to Folder") {
            Button("New Folder…") {
                if let id = store.addFolder() {
                    store.moveTab(tab.id, toFolder: id)
                    renamingFolderID = id
                }
            }
            if !store.activeSpaceFolders.isEmpty {
                Divider()
                ForEach(store.activeSpaceFolders) { folder in
                    Button(folder.displayName) { store.moveTab(tab.id, toFolder: folder.id) }
                }
            }
            if tab.folderID != nil {
                Divider()
                Button("Remove from Folder") { store.moveTab(tab.id, toFolder: nil) }
            }
        }

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
        HStack(spacing: 4) {
            Button {
                openCommandBar(.newTab, nil)
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

            // New Folder — creates a folder in the active Space, ready to rename.
            Button {
                if let id = store.addFolder() { renamingFolderID = id }
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 11))
                    .frame(width: Metrics.sidebarRowHeight, height: Metrics.sidebarRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Folder")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        // No keyboard shortcut here on purpose — see `collapseButton`.
    }
}
