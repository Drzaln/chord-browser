import ChordCore
import ChordEngine
import Foundation

/// Space management. Split from `TabStore.swift` to keep both files under the
/// ~400-line limit in BROWSER_SPEC 7.6.
@MainActor
extension TabStore {

    // MARK: - Spaces

    // The Space-derived collections live in `TabStore+WindowScoped`, asked per
    // window: `activeSpace(in:)`, `visibleTabs(in:)`, `pinnedTabs(in:)`, and so
    // on. There is no "the" active Space any more. The Pinned section's collapse
    // state is on `WindowState` for the same reason.

    /// - Parameter window: the window that switches. Only it moves — Cmd+1…9 in
    ///   Arc switches the focused window and leaves the others where they are.
    public func selectSpace(_ spaceID: UUID, in window: WindowState) {
        guard spaceID != window.activeSpaceID, let target = spaces.first(where: { $0.id == spaceID })
        else {
            return
        }
        // A window never crosses the private boundary in either direction: a
        // private window is locked to the Space it was born with, and a normal
        // window cannot be steered into one.
        guard target.isPrivate == window.isPrivate else { return }
        if window.isPrivate { guard spaceID == window.privateSpaceID else { return } }

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

        // Persist the layout change (v9): the common path sets the selection
        // directly without touching a tab, so nothing else would save it.
        scheduleSave()
    }

    /// `Cmd+1...9`. Out-of-range indices are ignored rather than clamped —
    /// Cmd+7 with three Spaces should do nothing, not jump to the last one.
    public func selectSpace(atIndex index: Int, in window: WindowState) {
        // `visibleSpaces`: Cmd+1…9 can never land on a private Space.
        let ordered = visibleSpaces.sorted { $0.sortIndex < $1.sortIndex }
        guard ordered.indices.contains(index) else { return }
        selectSpace(ordered[index].id, in: window)
    }

    @discardableResult
    public func addSpace(name: String? = nil, in window: WindowState) -> Space {
        let sortIndex = (spaces.map(\.sortIndex).max() ?? -1) + 1
        let space = Space(
            name: name ?? "Space \(spaces.count + 1)",
            gradient: Space.gradient(forIndex: sortIndex),
            sortIndex: sortIndex
        )
        spaces.append(space)
        Task { await persistSpaces() }
        // The window that made it goes there; the others stay put.
        selectSpace(space.id, in: window)
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
    public func deleteSpace(_ spaceID: UUID, in window: WindowState) async {
        guard visibleSpaces.count > 1, let index = spaces.firstIndex(where: { $0.id == spaceID })
        else { return }  // never leave the user with no Space
        // A private Space is owned by its window and dies with it; there is no
        // user-facing delete for one.
        guard !spaces[index].isPrivate else { return }

        let space = spaces[index]

        for tab in tabs where tab.spaceID == spaceID {
            for pane in tab.panes {
                engine.evict(paneID: pane.id)
                engine.forget(paneID: pane.id)
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

        if window.activeSpaceID == spaceID, let first = visibleSpaces.first {
            window.activeSpaceID = nil
            selectSpace(first.id, in: window)
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
            // `visibleSpaces`, never `spaces`: a private Space must not reach the
            // table, and `saveSpaces` replaces it wholesale, so this one line is
            // the whole guard for every Space mutation.
            try await spaceRepository?.saveSpaces(visibleSpaces)
        } catch {
            Log.store.error("space save failed: \(String(describing: error))")
        }
    }

}
