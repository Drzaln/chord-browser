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
/// Per-Space comes for free: `store.pinnedTabs` filters by the active Space,
/// so one Space's favourites can never appear in another.
struct PinnedGrid: View {
    @Bindable var store: TabStore

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 6), count: 4
    )

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(store.pinnedTabs) { tab in
                tile(tab)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func tile(_ tab: BrowserCore.Tab) -> some View {
        let isSelected = tab.id == store.selectedTabID

        return Button {
            store.select(tab.id)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.quaternary))

                favicon(for: tab)
                    .frame(width: 20, height: 20)
            }
            .frame(height: Metrics.pinnedTileHeight)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
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
            Button("Unpin") { store.setPinned(false, tabID: tab.id) }
            Button("Close Tab") { store.closeTab(tab.id) }
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
