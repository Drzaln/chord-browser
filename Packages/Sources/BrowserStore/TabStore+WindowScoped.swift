import BrowserCore
import Foundation

/// The store's derived collections, asked *per window*.
///
/// The no-argument forms in `TabStore+Spaces` are these with the primary window
/// filled in. They stay because most call sites — and every test — mean "the one
/// window there is"; these are what the UI uses once a second window exists.
@MainActor
extension TabStore {

    /// The Space `window` is looking at, falling back to the first Space when it
    /// is pointing at nothing (a fresh window) or at something deleted.
    public func activeSpace(in window: WindowState) -> Space? {
        guard let id = window.activeSpaceID else { return spaces.first }
        return spaces.first { $0.id == id } ?? spaces.first
    }

    /// The tabs `window` shows in its sidebar, in order.
    public func visibleTabs(in window: WindowState) -> [Tab] {
        guard let spaceID = activeSpace(in: window)?.id else { return [] }
        return tabs
            .filter { $0.spaceID == spaceID }
            .sorted { $0.placement.order < $1.placement.order }
    }

    /// The tab `window` is showing, if it still exists.
    public func selectedTab(in window: WindowState) -> Tab? {
        guard let id = window.selectedTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    /// The favourites grid for `window` (4.1). Foldered tabs render under their
    /// folder instead, so they are excluded.
    public func pinnedTabs(in window: WindowState) -> [Tab] {
        visibleTabs(in: window).filter { $0.placement.isPinned && $0.folderID == nil }
    }

    /// Arc's *Pinned* list section for `window`.
    public func bookmarkedTabs(in window: WindowState) -> [Tab] {
        visibleTabs(in: window).filter { $0.placement.isBookmarked && $0.folderID == nil }
    }

    /// The loose ephemeral tabs for `window` — the ones the sweep may take.
    public func unpinnedTabs(in window: WindowState) -> [Tab] {
        visibleTabs(in: window).filter { $0.placement.isEphemeral && $0.folderID == nil }
    }

    /// The folders in `window`'s Space, in order.
    public func folders(in window: WindowState) -> [Folder] {
        guard let spaceID = activeSpace(in: window)?.id else { return [] }
        return folders
            .filter { $0.spaceID == spaceID }
            .sorted { $0.sortIndex < $1.sortIndex }
    }
}
