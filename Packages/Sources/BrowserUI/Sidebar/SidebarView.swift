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
    /// This window's sidebar state — width, and which sections it has collapsed.
    @Bindable var windowState: WindowState
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
        SpaceTheme.accent(for: store.activeSpace(in: windowState) ?? Space.makeDefault())
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
                store: store, windowState: windowState, downloads: downloads,
                tint: spaceTint, openCommandBar: openCommandBar
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            spaceScopedSections
                // The Space switch, made visible (4.2). Everything below the
                // address bar belongs to *this* Space, so it is what travels;
                // the header and the switcher stay put, the way a window frame
                // stays put while its contents change.
                //
                // Driven by `spaceSwipeProgress` — which a trackpad swipe moves
                // continuously and `SpaceSwitchAnimator` springs for ⌘1…9 and a
                // click in the switcher — so all three paths are the *same*
                // movement rather than three that merely resemble each other.
                //
                // The web content card is deliberately not animated: it hosts a
                // live `WKWebView`, and §5 is explicit that layer transforms
                // there cost the compositor fast path. Arc slides its sidebar
                // too.
                .offset(x: -windowState.spaceSwipeProgress * Self.spaceSlideDistance)
                .opacity(1 - min(1, abs(windowState.spaceSwipeProgress)) * 0.6)
                // Clipped, or the travelling list paints over the page for the
                // length of the animation.
                .clipped()

            // Arc keeps the Space switcher on the bottom bar, under the tab
            // list, rather than above it. §4.1 lists it first; the order there
            // is about which sections exist, and the bottom is where the
            // interaction model this is copying puts it.
            Divider().opacity(0.5)
            // A private window is locked to its own throwaway Space, so there is
            // nothing to switch to and no "+" — the footer says where you are
            // instead of offering somewhere to go.
            if windowState.isPrivate {
                privateFooter
            } else {
                SpaceSwitcher(store: store, windowState: windowState)
            }
        }
        .frame(width: windowState.sidebarWidth)
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
            if let space = store.activeSpace(in: windowState) {
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
                                dragStartWidth = windowState.sidebarWidth
                                windowState.isSidebarResizing = true
                            }
                            if let startWidth = dragStartWidth {
                                let newWidth = startWidth + value.translation.width
                                windowState.sidebarWidth = min(max(newWidth, 160), 400)
                            }
                        }
                        .onEnded { _ in
                            dragStartWidth = nil
                            windowState.isSidebarResizing = false
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

                ForEach(store.unpinnedTabs(in: windowState)) { tab in
                    TabRowView(
                        tab: tab,
                        isSelected: tab.id == windowState.selectedTabID,
                        tint: spaceTint,
                        isPlayingAudio: store.runtime(for: tab.focusedPaneID).isPlayingAudio,
                        isMuted: store.runtime(for: tab.focusedPaneID).isMuted,
                        sleepTimerDeadline: store.runtime(for: tab.focusedPaneID).sleepTimerDeadline,
                        select: { store.select(tab.id, in: windowState) },
                        close: { store.closeTab(tab.id, in: windowState) },
                        toggleMute: { store.toggleMute(tab.id) },
                        cancelSleepTimer: { store.cancelSleepTimer(tab.id) },
                        beginDrag: { store.beginTabDrag(tab.id) },
                        endDrag: { store.endTabDrag() }
                    )
                    .id(tab.id)  // stable identity, so rows are not rebuilt
                    .contextMenu { rowMenu(for: tab) }
                }
            }
            .padding(.horizontal, 8)
        }
        // Fill the region between the New Tab button and the Space switcher so
        // the drop target below covers the empty area under the rows, not just
        // the rows themselves.
        .frame(maxHeight: .infinity)
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
                            // `dropTab`, not `reorderTab`: the tab may be
                            // arriving from another window, in a Space this one
                            // is not showing.
                            store.dropTab(
                                tabID,
                                into: .ephemeral,
                                at: insertionIndex(forY: point.y),
                                in: windowState
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
                .fill(SpaceTheme.accent(for: store.activeSpace(in: windowState) ?? Space.makeDefault()))
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
        return max(0, min(raw, store.unpinnedTabs(in: windowState).count))
    }

    /// Dropping onto the favourites grid pins the tab (4.1). Appends rather than
    /// placing at a grid cell — the grid has no obvious linear slot to aim for,
    /// and the last position is the predictable one.
    private var pinnedDropOverlay: some View {
        SidebarDropTarget(
            onDrop: { tabID, _ in
                store.dropTab(
                    tabID,
                    into: .favourite,
                    at: store.pinnedTabs(in: windowState).count,
                    in: windowState
                )
            }
        )
    }

    /// A collapsible header for the Pinned section: a disclosure chevron, the
    /// label, and the count. Modelled on the folder headers, but the whole row
    /// toggles rather than renaming. During a drag it doubles as a drop target,
    /// so a tab can be pinned even while the list is collapsed.
    private var pinnedSectionHeader: some View {
        let collapsed = windowState.isPinnedSectionCollapsed(inSpace: store.activeSpace(in: windowState)?.id)
        return HStack(spacing: 6) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Image(systemName: "pin.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("Pinned")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(store.bookmarkedTabs(in: windowState).count)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .frame(height: Metrics.sidebarRowHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            windowState.togglePinnedSectionCollapsed(inSpace: store.activeSpace(in: windowState)?.id)
        }
        .overlay { if isDragging { bookmarkDropOverlay } }
        .padding(.horizontal, 8)
        .accessibilityLabel("Pinned tabs, \(store.bookmarkedTabs(in: windowState).count)")
        .accessibilityAddTraits(.isButton)
    }

    /// Dropping onto the Pinned list pins the tab as an Arc *Pinned* tab (4.1),
    /// appending it to the end of the section.
    private var bookmarkDropOverlay: some View {
        SidebarDropTarget(
            onDrop: { tabID, _ in
                store.dropTab(
                    tabID,
                    into: .pinned,
                    at: store.bookmarkedTabs(in: windowState).count,
                    in: windowState
                )
            }
        )
    }

    /// Shown in place of the (absent) Pinned list while dragging, so the first
    /// Pinned tab in a Space can be made by dragging a tab onto it.
    private var firstBookmarkDropZone: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4]))
            .frame(height: Metrics.sidebarRowHeight)
            .overlay {
                Label("Pin Tab", systemImage: "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .overlay { bookmarkDropOverlay }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
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
        windowState.spaceSwipeProgress == 0
            ? SpaceTheme.gradient(for: space)
            : SpaceTheme.gradient(stops: store.swipeBlendedGradient(in: windowState))
    }

    /// Clears the traffic lights, and carries the collapse control beside them
    /// the way the rest of the platform does.
    private var header: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if let extensionHost {
                ExtensionActionsBar(
                    store: store, windowState: windowState, host: extensionHost
                )
                    .padding(.trailing, 4)
            }
            collapseButton
        }
        .frame(height: Metrics.titlebarInset)
        .padding(.trailing, 8)
    }

    private var collapseButton: some View {
        Button {
            windowState.isSidebarCollapsed.toggle()
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
        ForEach(store.folders(in: windowState)) { folder in
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
                        isSelected: tab.id == windowState.selectedTabID,
                        tint: spaceTint,
                        isPlayingAudio: store.runtime(for: tab.focusedPaneID).isPlayingAudio,
                        isMuted: store.runtime(for: tab.focusedPaneID).isMuted,
                        sleepTimerDeadline: store.runtime(for: tab.focusedPaneID).sleepTimerDeadline,
                        select: { store.select(tab.id, in: windowState) },
                        close: { store.closeTab(tab.id, in: windowState) },
                        toggleMute: { store.toggleMute(tab.id) },
                        cancelSleepTimer: { store.cancelSleepTimer(tab.id) },
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
        if !tab.placement.isBookmarked {
            Button("Pin Tab") { store.setBookmarked(true, tabID: tab.id) }
        }

        Button(store.isMuted(tab.id) ? "Unmute Tab" : "Mute Tab") {
            store.toggleMute(tab.id)
        }

        SleepTimerMenu(store: store, tab: tab)

        // Move to / out of a folder (non-spec: user-requested).
        Menu("Move to Folder") {
            Button("New Folder…") {
                if let id = store.addFolder() {
                    store.moveTab(tab.id, toFolder: id)
                    renamingFolderID = id
                }
            }
            if !store.folders(in: windowState).isEmpty {
                Divider()
                ForEach(store.folders(in: windowState)) { folder in
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
            // A tab can only be moved between real Spaces — never into or out
            // of a private window's throwaway one.
            ForEach(store.visibleSpaces.filter { $0.id != tab.spaceID }) { space in
                Button(space.name) { store.moveTab(tab.id, toSpace: space.id, in: windowState) }
            }
        }
        .disabled(store.visibleSpaces.count <= 1)
    }

    /// What a private window has instead of the Space switcher.
    ///
    /// The copy is deliberately in two halves, in the same register as the
    /// vault's lock text: what this actually does, and — because "incognito" is
    /// the most over-read word in any browser — what it plainly does not.
    private var privateFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 11, weight: .medium))
                Text("Private window")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(
                "Nothing here is written to disk — no history, no saved tabs, no cookies. "
                    + "Close the window and the session is gone.\n"
                    + "It does not hide you from the sites you visit or from your network. "
                    + "Downloads and passwords you fill are real."
            )
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// How far the Space-scoped sections travel at full progress. The sidebar's
    /// own width, so a switch reads as this Space leaving and the next arriving
    /// rather than a nudge.
    private static let spaceSlideDistance: CGFloat = Metrics.sidebarWidth

    /// Everything that belongs to the active Space, and so everything that
    /// moves when the Space changes.
    @ViewBuilder
    private var spaceScopedSections: some View {
        VStack(spacing: 0) {
            // §4.1's sections, in order. The pinned grid is skipped entirely
            // when empty rather than left as a gap — an empty grid in a fresh
            // Space reads as something failing to load. During a drag an empty
            // section still shows a drop zone, so the first favourite can be
            // made by dragging.
            // A private window has neither pinned tier and no drop zones for
            // them: both promise the tab will still be there, and its Space
            // evaporates when the window closes (`TabStore+Private`).
            if !windowState.isPrivate {
                if !store.pinnedTabs(in: windowState).isEmpty {
                    PinnedGrid(store: store, windowState: windowState)
                        .overlay { if isDragging { pinnedDropOverlay } }
                } else if isDragging {
                    firstPinDropZone
                }
            }

            // Arc's "Pinned" tabs — a list section under the favourites grid and
            // above the New Tab affordance. It has a collapsible header so a long
            // list does not push the ephemeral tabs off-screen. Skipped entirely
            // when empty except during a drag, when a drop zone lets the first
            // Pinned tab be made.
            if !windowState.isPrivate {
                if !store.bookmarkedTabs(in: windowState).isEmpty {
                    pinnedSectionHeader
                    if !windowState.isPinnedSectionCollapsed(
                        inSpace: store.activeSpace(in: windowState)?.id
                    ) {
                        PinnedList(store: store, windowState: windowState, tint: spaceTint)
                            .overlay { if isDragging { bookmarkDropOverlay } }
                    }
                } else if isDragging {
                    firstBookmarkDropZone
                }
            }

            newTabButton

            // Fills the space down to the Space switcher rather than hugging its
            // rows, so its overlaid drop target covers the empty area below the
            // last tab too — a drop there appends, the way most browsers accept a
            // drop anywhere in the list. (The old `Spacer(minLength: 0)` here
            // split that slack with the list and left the gap undroppable.)
            ephemeralList

        }
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
