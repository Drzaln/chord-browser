import ChordCore
import ChordExtensions
import Foundation

/// `TabStore` as the data source the extension tab/window adapters read (M7,
/// 7.3b). WebKit-free — the adapters live below the Store and pull tab state up
/// through this protocol, defined in `ChordExtensions` and injected downward
/// (§3.5). Everything is Space-scoped, because extensions are per-Space
/// (ADR 011).
extension TabStore: ExtensionTabModel {
    public func extensionTabs(inSpace spaceID: UUID) -> [ExtensionTabSnapshot] {
        tabsInSpace(spaceID).enumerated().map { index, tab in
            snapshot(of: tab, index: index)
        }
    }

    public func extensionActiveTab(inSpace spaceID: UUID) -> ExtensionTabSnapshot? {
        // WebExtensions treat a Space as a window (ADR 011), so "active" means
        // whatever the window sitting in this Space has selected.
        guard let selected = window(inSpace: spaceID)?.selectedTabID,
            let tab = tabs.first(where: { $0.id == selected }),
            tab.spaceID == spaceID
        else { return nil }
        let index = tabsInSpace(spaceID).firstIndex { $0.id == tab.id } ?? 0
        return snapshot(of: tab, index: index)
    }

    public func extensionFocusedPaneID(_ tabID: UUID) -> UUID? {
        tabs.first { $0.id == tabID }?.focusedPaneID
    }

    public func extensionTab(_ tabID: UUID) -> ExtensionTabSnapshot? {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return nil }
        let index = tabsInSpace(tab.spaceID).firstIndex { $0.id == tabID } ?? 0
        return snapshot(of: tab, index: index)
    }

    /// Reloads every live pane of every tab in a Space. Called after an
    /// extension is granted host access on enable, so its content scripts inject
    /// into pages that are already open. `engine.reload` is a no-op for a pane
    /// with no live view, so unopened tabs cost nothing and pick the extension up
    /// on their first load.
    public func reloadTabs(inSpace spaceID: UUID) {
        for tab in tabsInSpace(spaceID) {
            for pane in tab.panes {
                engine.reload(paneID: pane.id)
            }
        }
    }

    // MARK: - Actions

    public func extensionCreateTab(
        url: URL, inSpace spaceID: UUID, active: Bool
    ) -> ExtensionTabSnapshot? {
        let window = window(inSpace: spaceID) ?? focusedWindow
        let id = newTab(url: url, in: window, selecting: active)
        guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
        let index = tabsInSpace(tab.spaceID).firstIndex { $0.id == id } ?? 0
        return snapshot(of: tab, index: index)
    }

    public func extensionActivateTab(_ tabID: UUID) {
        // The window already in that tab's Space, so an extension activating a
        // tab does not drag an unrelated window along with it.
        select(tabID, in: tabs.first { $0.id == tabID }
            .flatMap { window(inSpace: $0.spaceID) } ?? primaryWindow)
    }

    public func extensionLoadURL(_ url: URL, inTab tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        engine.load(url, in: tab.focusedPaneID)
        updatePane(tab.focusedPaneID) { $0.url = url }
        scheduleSave()
    }

    public func extensionReloadTab(_ tabID: UUID, fromOrigin: Bool) {
        // WebKit's reload has no from-origin distinction we expose; a plain
        // reload is the honest mapping. `fromOrigin` is accepted so the adapter
        // signature matches without lying about a cache-bypass we cannot do.
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        engine.reload(paneID: tab.focusedPaneID)
    }

    public func extensionGoBack(inTab tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        engine.goBack(in: tab.focusedPaneID)
    }

    public func extensionGoForward(inTab tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        engine.goForward(in: tab.focusedPaneID)
    }

    public func extensionCloseTab(_ tabID: UUID) {
        closeTab(tabID, in: tabs.first { $0.id == tabID }
            .flatMap { window(inSpace: $0.spaceID) } ?? primaryWindow)
    }

    /// `chrome.tabs.move` within one Space, or into another.
    ///
    /// Chord's visual order has three sections (favourites, Pinned, ephemeral),
    /// so Chrome's flat index is clamped into the tab's own section. A tab
    /// moving to another Space takes that Space's data store with it, exactly
    /// like a drag across Spaces (`moveTab` evicts the panes first).
    public func extensionMoveTab(_ tabID: UUID, to index: Int, inSpace spaceID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        if tab.spaceID != spaceID {
            extensionMoveTab(tabID, toSpace: spaceID, at: index)
            return
        }
        guard let from = tabsInSpace(spaceID).firstIndex(where: { $0.id == tabID })
        else { return }
        reorderTab(tabID, to: section(of: tab.placement), at: index)
        extensionHost?.extensionTabDidMove(tabID, from: from, inSpace: spaceID)
    }

    /// `chrome.tabs.move` with a different `windowId`. A window is a Space in
    /// Chord, so this is the same Space change the sidebar confirms for a drag;
    /// an extension asked for it, so there is no prompt.
    public func extensionMoveTab(_ tabID: UUID, toSpace spaceID: UUID, at index: Int) {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              tab.spaceID != spaceID,
              spaces.contains(where: { $0.id == spaceID })
        else {
            extensionMoveTab(tabID, to: index, inSpace: spaceID)
            return
        }
        let window = window(inSpace: spaceID) ?? focusedWindow
        moveTab(tabID, toSpace: spaceID, in: window)
        reorderTab(tabID, to: section(of: tab.placement), at: index)
        extensionHost?.extensionTabDidMove(tabID, from: 0, inSpace: spaceID)
    }

    // MARK: -

    private func tabsInSpace(_ spaceID: UUID) -> [Tab] {
        tabs
            .filter { $0.spaceID == spaceID }
            .sorted { $0.placement.order < $1.placement.order }
    }

    private func snapshot(of tab: Tab, index: Int) -> ExtensionTabSnapshot {
        let runtime = runtime(for: tab.focusedPaneID)
        let space = spaces.first { $0.id == tab.spaceID }
        let spaceFolders = folders
            .filter { $0.spaceID == tab.spaceID }
            .sorted { $0.sortIndex < $1.sortIndex }
        let groupNumber = tab.folderID.flatMap { id in
            spaceFolders.firstIndex { $0.id == id }.map { $0 + 1 }
        }
        return ExtensionTabSnapshot(
            id: tab.id,
            spaceID: tab.spaceID,
            focusedPaneID: tab.focusedPaneID,
            url: runtime.currentURL ?? tab.focusedPane.url,
            title: tab.displayTitle,
            isSelected: isSelectedByAnyWindow(tab.id),
            index: index,
            faviconData: tab.focusedPane.faviconData,
            isPinned: !tab.placement.isEphemeral,
            isAudible: runtime.isPlayingAudio,
            isMuted: runtime.isMuted,
            isLoading: runtime.isLoading,
            groupID: tab.folderID,
            groupNumber: groupNumber,
            isPrivate: space?.isPrivate ?? false
        )
    }
}
