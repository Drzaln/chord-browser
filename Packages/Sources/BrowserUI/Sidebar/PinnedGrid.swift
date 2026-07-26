import BrowserCore
import BrowserStore
import SwiftUI

/// The active Space's favourites, as a grid of favicon tiles (4.1).
///
/// Pinned tabs were already in the model and the schema from M1 —
/// `TabPlacement.pinned` — and the sidebar simply never separated them from
/// the ephemeral ones. Nothing here is new state; it is the section §4.1 asked
/// for, finally rendered.
///
/// Per-Space comes for free: `store.pinnedTabs(in: windowState)` filters by the active Space,
/// so one Space's favourites can never appear in another.
struct PinnedGrid: View {
    @Bindable var store: TabStore
    /// The window this view belongs to — its selection, its Space.
    @Bindable var windowState: WindowState

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 6), count: 4
    )

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(store.pinnedTabs(in: windowState)) { tab in
                tile(tab)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func tile(_ tab: BrowserCore.Tab) -> some View {
        let isSelected = tab.id == windowState.selectedTabID
        // Tinted with the Space colour, matching the tab rows and the address
        // button (items 1 and 4).
        let tint = SpaceTheme.accent(for: store.activeSpace(in: windowState) ?? Space.makeDefault())

        return Button {
            store.select(tab.id, in: windowState)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.40) : tint.opacity(0.14))

                favicon(for: tab)
                    .frame(width: 20, height: 20)
            }
            .frame(height: Metrics.pinnedTileHeight)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        // A drag source, like the ephemeral rows (4.1), so a favourite can be
        // dragged out to unpin it, onto a Space to move it, or reordered. An
        // AppKit source rather than `onDrag` — see `TabDragSource`.
        .overlay {
            TabDragSource(
                tabID: tab.id,
                title: tab.displayTitle,
                onDragBegan: { store.beginTabDrag(tab.id) },
                onDragEnded: { store.endTabDrag() },
                onClick: { store.select(tab.id, in: windowState) },
                // Double-click returns the favourite to the URL it was pinned at.
                onDoubleClick: { store.returnToPinnedHome(tab.id, in: windowState) }
            )
        }
        .overlay(alignment: .bottomTrailing) {
            // Arc marks a favourite whose page has changed since you last
            // looked. Audio is the one "something is happening here" signal
            // this app actually has (4.3, ADR 008) — it is not the same thing,
            // but inventing an unread-tracker is a feature nobody asked for.
            if store.runtime(for: tab.focusedPaneID).isPlayingAudio {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .padding(6)
            }
        }
        .help(tab.displayTitle)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            Button("Return to Pinned URL") { store.returnToPinnedHome(tab.id, in: windowState) }
                .disabled(tab.placement.homeURL == nil || tab.placement.homeURL == tab.focusedPane.url)
            Button("Set Current Page as Pinned URL") { store.updatePinnedHome(tab.id) }
                .disabled(tab.placement.homeURL == tab.focusedPane.url)
            Button("Unpin") { store.setPinned(false, tabID: tab.id) }
            Button(store.isMuted(tab.id) ? "Unmute Tab" : "Mute Tab") {
                store.toggleMute(tab.id)
            }
            Button("Close Tab") { store.closeTab(tab.id, in: windowState) }
        }
    }

    @ViewBuilder
    private func favicon(for tab: BrowserCore.Tab) -> some View {
        if let image = FaviconCache.shared.image(
            paneID: tab.focusedPaneID, data: tab.focusedPane.faviconData
        ) {
            image.resizable().interpolation(.high)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }
}
