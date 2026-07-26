import BrowserCore
import BrowserEngine
import Foundation

/// Space management. Split from `TabStore.swift` to keep both files under the
/// ~400-line limit in BROWSER_SPEC 7.6.
@MainActor
extension TabStore {

    // MARK: - Spaces

    public var activeSpace: Space? {
        guard let activeSpaceID else { return spaces.first }
        return spaces.first { $0.id == activeSpaceID } ?? spaces.first
    }

    /// The sidebar shows only the active Space's tabs. Partitioning happens in
    /// memory: the tab set is small, and going to disk on every Space switch
    /// would blow the 100 ms budget in 6.1.
    public var visibleTabs: [Tab] {
        guard let spaceID = activeSpace?.id else { return [] }
        return tabs
            .filter { $0.spaceID == spaceID }
            .sorted { $0.placement.order < $1.placement.order }
    }

    /// The active Space's pinned tabs — its favourites (4.1). Tabs inside a
    /// folder are shown under the folder instead, so they are excluded here.
    ///
    /// Per-Space for free: `visibleTabs` is already filtered by the active
    /// Space, so a Space's favourites cannot leak into another's.
    public var pinnedTabs: [Tab] {
        visibleTabs.filter { $0.placement.isPinned && $0.folderID == nil }
    }

    /// The active Space's Arc-style *Pinned* tabs — the list section between the
    /// favourites grid and the loose tabs (non-spec: user-requested). Foldered
    /// tabs are shown under their folder instead, so they are excluded here.
    public var bookmarkedTabs: [Tab] {
        visibleTabs.filter { $0.placement.isBookmarked && $0.folderID == nil }
    }

    // The Pinned section's collapse state moved to `WindowState` — it is
    // per-window, so two windows in one Space can disagree about it.

    /// The loose ephemeral tabs the sweep may eventually close — neither a
    /// favourite nor a Pinned tab, and not in a folder.
    public var unpinnedTabs: [Tab] {
        visibleTabs.filter { $0.placement.isEphemeral && $0.folderID == nil }
    }

    /// - Parameter window: the window that switches. Only it moves — Cmd+1…9 in
    ///   Arc switches the focused window and leaves the others where they are.
    public func selectSpace(_ spaceID: UUID, in window: WindowState? = nil) {
        let window = window ?? primaryWindow
        guard spaceID != window.activeSpaceID, spaces.contains(where: { $0.id == spaceID })
        else {
            return
        }

        let state = Log.signposts.beginInterval("spaceSwitch")
        defer { Log.signposts.endInterval("spaceSwitch", state) }

        if let current = window.activeSpaceID, let selected = window.selectedTabID {
            lastSelectedTabBySpace[current] = selected
        }
        window.activeSpaceID = spaceID

        // Web views for the other Space stay live and stay in the pool — the
        // LRU cap is what bounds them. Evicting on switch would make going back
        // a reload, which is the opposite of the 100 ms budget.
        let candidates = visibleTabs(in: window)
        if let remembered = lastSelectedTabBySpace[spaceID],
           candidates.contains(where: { $0.id == remembered }) {
            window.selectedTabID = remembered
        } else {
            window.selectedTabID = candidates.max { $0.lastAccessedAt < $1.lastAccessedAt }?.id
        }

        if window.selectedTabID == nil { newTab(in: window) }
    }

    /// `Cmd+1...9`. Out-of-range indices are ignored rather than clamped —
    /// Cmd+7 with three Spaces should do nothing, not jump to the last one.
    public func selectSpace(atIndex index: Int, in window: WindowState? = nil) {
        let ordered = spaces.sorted { $0.sortIndex < $1.sortIndex }
        guard ordered.indices.contains(index) else { return }
        selectSpace(ordered[index].id, in: window ?? primaryWindow)
    }

    @discardableResult
    public func addSpace(name: String? = nil, in window: WindowState? = nil) -> Space {
        let sortIndex = (spaces.map(\.sortIndex).max() ?? -1) + 1
        let space = Space(
            name: name ?? "Space \(spaces.count + 1)",
            gradient: Space.gradient(forIndex: sortIndex),
            sortIndex: sortIndex
        )
        spaces.append(space)
        Task { await persistSpaces() }
        // The window that made it goes there; the others stay put.
        selectSpace(space.id, in: window ?? primaryWindow)
        return space
    }

    public func renameSpace(_ spaceID: UUID, to name: String) {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        spaces[index].name = name
        Task { await persistSpaces() }
    }

    /// Sets a Space's icon and gradient. Both are already free-form persisted
    /// columns, so custom emoji and colours need no migration. Empty inputs are
    /// ignored rather than blanking the Space to an unrenderable state; the
    /// gradient falls back to the default if the caller hands over nothing.
    /// `SpaceTheme`'s cache invalidates itself when the stops change, so nothing
    /// here has to poke the UI.
    public func setSpaceAppearance(
        _ spaceID: UUID, icon: String, gradient: [ColorHex]
    ) {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        let trimmed = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { spaces[index].iconSymbol = trimmed }
        spaces[index].gradient = gradient.isEmpty ? Space.defaultGradient : gradient
        Task { await persistSpaces() }
    }

    /// Closes the Space's tabs and reclaims its disk. Irreversible — callers
    /// must have confirmed with the user first (3.3).
    public func deleteSpace(_ spaceID: UUID, in window: WindowState? = nil) async {
        let window = window ?? primaryWindow
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == spaceID })
        else { return }  // never leave the user with no Space

        let space = spaces[index]

        for tab in tabs where tab.spaceID == spaceID {
            for pane in tab.panes {
                engine.evict(paneID: pane.id)
                runtimes[pane.id] = nil
            }
        }
        tabs.removeAll { $0.spaceID == spaceID }
        // The DB cascades folder rows on space delete; keep the in-memory list in
        // step so the sidebar does not show a folder from a Space that is gone.
        folders.removeAll { $0.spaceID == spaceID }
        persistFolders()
        spaces.remove(at: index)
        lastSelectedTabBySpace[spaceID] = nil

        if window.activeSpaceID == spaceID {
            window.activeSpaceID = nil
            selectSpace(spaces[0].id, in: window)
        }
        // Any other window sitting in the deleted Space is re-homed to the first
        // one, the same rule `adoptOrphanedTabs` uses for a tab.
        reconcileWindows(excluding: window)

        do {
            try await engine.removeData(for: space)
        } catch {
            // The Space is already gone from the user's view; a failed disk
            // reclaim is a log line, not a failed operation.
            Log.store.error("failed to remove data for space: \(String(describing: error))")
        }

        await persistSpaces()
        scheduleSave()
    }

    func persistSpaces() async {
        do {
            try await spaceRepository?.saveSpaces(spaces)
        } catch {
            Log.store.error("space save failed: \(String(describing: error))")
        }
    }

    public var selectedTab: Tab? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

}
