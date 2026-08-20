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

    // MARK: -

    private func tabsInSpace(_ spaceID: UUID) -> [Tab] {
        tabs
            .filter { $0.spaceID == spaceID }
            .sorted { $0.placement.order < $1.placement.order }
    }

    private func snapshot(of tab: Tab, index: Int) -> ExtensionTabSnapshot {
        let pane = tab.focusedPane
        return ExtensionTabSnapshot(
            id: tab.id,
            spaceID: tab.spaceID,
            focusedPaneID: tab.focusedPaneID,
            url: pane.url,
            title: pane.displayTitle,
            isSelected: isSelectedByAnyWindow(tab.id),
            index: index
        )
    }
}
