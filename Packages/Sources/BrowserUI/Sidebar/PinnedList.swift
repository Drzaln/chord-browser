import BrowserCore
import BrowserStore
import SwiftUI

/// The active Space's Arc-style *Pinned* tabs, as a list of rows between the
/// favourites grid and the New Tab affordance (non-spec: user-requested).
///
/// Distinct from the favourites `PinnedGrid`: a Pinned tab is a full row with
/// its title, and it remembers the URL it was pinned at. Selecting a Pinned tab
/// that is already selected returns it to that home URL — Arc's "click the icon
/// to return to where it was pinned" behaviour.
///
/// Per-Space comes for free: `store.bookmarkedTabs(in: windowState)` filters by the active Space.
struct PinnedList: View {
    @Bindable var store: TabStore
    /// The window this view belongs to — its selection, its Space.
    @Bindable var windowState: WindowState
    var tint: Color = .accentColor

    var body: some View {
        LazyVStack(spacing: 2) {
            ForEach(store.bookmarkedTabs(in: windowState)) { tab in
                TabRowView(
                    tab: tab,
                    isSelected: tab.id == windowState.selectedTabID,
                    tint: tint,
                    isPlayingAudio: store.runtime(for: tab.focusedPaneID).isPlayingAudio,
                    isMuted: store.runtime(for: tab.focusedPaneID).isMuted,
                    sleepTimerDeadline: store.runtime(for: tab.focusedPaneID).sleepTimerDeadline,
                    select: { selectOrReturnHome(tab) },
                    close: { store.closeTab(tab.id, in: windowState) },
                    toggleMute: { store.toggleMute(tab.id) },
                    cancelSleepTimer: { store.cancelSleepTimer(tab.id) },
                    beginDrag: { store.beginTabDrag(tab.id) },
                    endDrag: { store.endTabDrag() }
                )
                .id(tab.id)
                .contextMenu {
                    Button("Rename Tab…") { windowState.renamingTabID = tab.id }
                    Button("Return to Pinned URL") { store.returnToPinnedHome(tab.id, in: windowState) }
                        .disabled(tab.placement.homeURL == tab.focusedPane.url)
                    Button("Set Current Page as Pinned URL") { store.updatePinnedHome(tab.id) }
                        .disabled(tab.placement.homeURL == tab.focusedPane.url)
                    Button("Unpin") { store.setBookmarked(false, tabID: tab.id) }
                    Button("Add to Favourites") { store.setPinned(true, tabID: tab.id) }
                    Button(store.isMuted(tab.id) ? "Unmute Tab" : "Mute Tab") {
                        store.toggleMute(tab.id)
                    }
                    SleepTimerMenu(store: store, tab: tab)
                    Button("Close Tab") { store.closeTab(tab.id, in: windowState) }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    /// First click focuses the Pinned tab; a click on the already-selected tab
    /// snaps it back to the URL it was pinned at (4.1).
    private func selectOrReturnHome(_ tab: BrowserCore.Tab) {
        if tab.id == windowState.selectedTabID {
            store.returnToPinnedHome(tab.id, in: windowState)
        } else {
            store.select(tab.id, in: windowState)
        }
    }
}
