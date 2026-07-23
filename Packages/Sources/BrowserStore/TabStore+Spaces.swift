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

    public func selectSpace(_ spaceID: UUID) {
        guard spaceID != activeSpaceID, spaces.contains(where: { $0.id == spaceID }) else {
            return
        }

        let state = Log.signposts.beginInterval("spaceSwitch")
        defer { Log.signposts.endInterval("spaceSwitch", state) }

        if let current = activeSpaceID, let selected = selectedTabID {
            lastSelectedTabBySpace[current] = selected
        }
        activeSpaceID = spaceID

        // Web views for the other Space stay live and stay in the pool — the
        // LRU cap is what bounds them. Evicting on switch would make going back
        // a reload, which is the opposite of the 100 ms budget.
        let candidates = visibleTabs
        if let remembered = lastSelectedTabBySpace[spaceID],
           candidates.contains(where: { $0.id == remembered }) {
            selectedTabID = remembered
        } else {
            selectedTabID = candidates.max { $0.lastAccessedAt < $1.lastAccessedAt }?.id
        }

        if selectedTabID == nil { newTab() }
    }

    /// `Cmd+1...9`. Out-of-range indices are ignored rather than clamped —
    /// Cmd+7 with three Spaces should do nothing, not jump to the last one.
    public func selectSpace(atIndex index: Int) {
        let ordered = spaces.sorted { $0.sortIndex < $1.sortIndex }
        guard ordered.indices.contains(index) else { return }
        selectSpace(ordered[index].id)
    }

    @discardableResult
    public func addSpace(name: String? = nil) -> Space {
        let sortIndex = (spaces.map(\.sortIndex).max() ?? -1) + 1
        let space = Space(
            name: name ?? "Space \(spaces.count + 1)",
            gradient: Space.gradient(forIndex: sortIndex),
            sortIndex: sortIndex
        )
        spaces.append(space)
        Task { await persistSpaces() }
        selectSpace(space.id)
        return space
    }

    public func renameSpace(_ spaceID: UUID, to name: String) {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        spaces[index].name = name
        Task { await persistSpaces() }
    }

    /// Closes the Space's tabs and reclaims its disk. Irreversible — callers
    /// must have confirmed with the user first (3.3).
    public func deleteSpace(_ spaceID: UUID) async {
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
        spaces.remove(at: index)
        lastSelectedTabBySpace[spaceID] = nil

        if activeSpaceID == spaceID {
            activeSpaceID = nil
            selectSpace(spaces[0].id)
        }

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
