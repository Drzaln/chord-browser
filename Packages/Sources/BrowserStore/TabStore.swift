import BrowserCore
import BrowserEngine
import Foundation
import Observation
import os

enum Log {
    static let store = Logger(subsystem: "com.rizal.browser", category: "store")
    static let signposts = OSSignposter(
        subsystem: "com.rizal.browser", category: "lifecycle"
    )
}

/// Owns app state and the engine. The UI layer talks only to this.
@MainActor
@Observable
public final class TabStore {
    public internal(set) var tabs: [Tab] = []
    public internal(set) var spaces: [Space] = []
    public internal(set) var activeSpaceID: UUID?
    public var selectedTabID: UUID?

    @ObservationIgnored let engine: any WebEngine
    @ObservationIgnored private let repository: any TabRepository
    @ObservationIgnored let spaceRepository: (any SpaceRepository)?
    @ObservationIgnored let historyRepository: (any HistoryRepository)?
    @ObservationIgnored let archiveRepository: (any ArchiveRepository)?
    @ObservationIgnored let clock: any Clock

    /// How long an unpinned tab may sit idle. User-configurable; "never" is
    /// allowed and disables the sweep (4.3).
    public var idleWindow: IdleWindow = .default

    @ObservationIgnored var sweepTask: Task<Void, Never>?
    @ObservationIgnored var isOccluded = false

    /// Refreshed when the command bar opens, so keystrokes never hit the disk.
    @ObservationIgnored var cachedHistory: [HistoryEntry] = []
    @ObservationIgnored var cachedArchive: [ArchivedTab] = []
    @ObservationIgnored var runtimes: [UUID: PaneRuntime] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Switching back to a Space should land where you left it.
    @ObservationIgnored var lastSelectedTabBySpace: [UUID: UUID] = [:]

    /// Tab state is written debounced and coalesced, never per navigation (6.5).
    @ObservationIgnored private let saveDebounce: Duration = .seconds(2)

    public static let defaultNewTabURL = URL(string: "https://www.google.com")!

    public init(
        engine: any WebEngine,
        repository: any TabRepository,
        spaceRepository: (any SpaceRepository)? = nil,
        historyRepository: (any HistoryRepository)? = nil,
        archiveRepository: (any ArchiveRepository)? = nil,
        clock: any Clock
    ) {
        self.engine = engine
        self.repository = repository
        self.spaceRepository = spaceRepository
        self.historyRepository = historyRepository
        self.archiveRepository = archiveRepository
        self.clock = clock
        self.engine.delegate = self
    }

    // MARK: - Lifecycle

    public func restore() async {
        let state = Log.signposts.beginInterval("restore")
        defer { Log.signposts.endInterval("restore", state) }

        do {
            spaces = try await spaceRepository?.loadSpaces() ?? []
        } catch {
            Log.store.error("space restore failed: \(String(describing: error))")
            spaces = []
        }
        if spaces.isEmpty {
            spaces = [Space.makeDefault()]
            await persistSpaces()
        }
        activeSpaceID = spaces[0].id

        do {
            tabs = try await repository.loadAll()
        } catch {
            // A failed load must not stop the app from opening. Start empty and
            // say so loudly; the file is still on disk and backed up.
            Log.store.error("tab restore failed, starting empty: \(String(describing: error))")
            tabs = []
        }
        adoptOrphanedTabs()

        if visibleTabs.isEmpty {
            newTab(url: Self.defaultNewTabURL)
        } else {
            // Restored tabs are lazy: no web view exists until one is activated.
            selectedTabID = visibleTabs.max { $0.lastAccessedAt < $1.lastAccessedAt }?.id
        }

        startSweep()
    }

    /// A tab whose Space no longer exists would be invisible everywhere, which
    /// reads to the user as data loss. Re-home it instead of dropping it (7.2).
    private func adoptOrphanedTabs() {
        guard let fallback = spaces.first else { return }
        let known = Set(spaces.map(\.id))

        var adopted = 0
        for index in tabs.indices where !known.contains(tabs[index].spaceID) {
            tabs[index].spaceID = fallback.id
            adopted += 1
        }
        if adopted > 0 {
            Log.store.notice("adopted \(adopted, privacy: .public) orphaned tab(s)")
            scheduleSave()
        }
    }

    // MARK: - Commands

    public func newTab(url: URL = TabStore.defaultNewTabURL) {
        guard let spaceID = activeSpace?.id else { return }

        // Order is per-Space, so a new tab in one Space does not push another
        // Space's tabs down the list.
        let order = (visibleTabs.map(\.placement.order).max() ?? -1) + 1
        let tab = Tab(
            url: url, spaceID: spaceID, placement: .ephemeral(order: order), now: clock.now
        )
        tabs.append(tab)
        selectedTabID = tab.id
        scheduleSave()
    }

    /// Moves a tab to another Space. The pane's web view is torn down first: it
    /// belongs to the old Space's data store and must not carry those cookies
    /// across.
    public func moveTab(_ tabID: UUID, toSpace spaceID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[index].spaceID != spaceID,
              spaces.contains(where: { $0.id == spaceID })
        else { return }

        for pane in tabs[index].panes {
            engine.evict(paneID: pane.id)
        }

        let order = (tabs.filter { $0.spaceID == spaceID }.map(\.placement.order).max() ?? -1) + 1
        tabs[index].spaceID = spaceID
        tabs[index].placement = tabs[index].placement.withOrder(order)

        if selectedTabID == tabID {
            selectedTabID = visibleTabs.first?.id
            if selectedTabID == nil { newTab() }
        }
        scheduleSave()
    }

    public func closeTab(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        for pane in tabs[index].panes {
            engine.evict(paneID: pane.id)
            runtimes[pane.id] = nil
        }
        let neighbours = visibleTabs
        let closedPosition = neighbours.firstIndex { $0.id == tabID }
        tabs.remove(at: index)

        if selectedTabID == tabID {
            // Select the neighbour that is now in the closed tab's slot, within
            // this Space only.
            let remaining = visibleTabs
            if let closedPosition, remaining.indices.contains(closedPosition) {
                selectedTabID = remaining[closedPosition].id
            } else {
                selectedTabID = remaining.last?.id
            }
        }
        if visibleTabs.isEmpty { newTab() }
        scheduleSave()
    }

    /// Pinning exempts a tab from the ephemeral sweep (4.3). Order is
    /// recomputed within the destination section so the two lists stay dense.
    public func setPinned(_ pinned: Bool, tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[index].placement.isPinned != pinned
        else { return }

        let spaceID = tabs[index].spaceID
        let order = tabs
            .filter { $0.spaceID == spaceID && $0.placement.isPinned == pinned }
            .map(\.placement.order)
            .max()
            .map { $0 + 1 } ?? 0

        tabs[index].placement = pinned ? .pinned(order: order) : .ephemeral(order: order)
        scheduleSave()
    }

    public func pin(_ tabID: UUID) { setPinned(true, tabID: tabID) }
    public func unpin(_ tabID: UUID) { setPinned(false, tabID: tabID) }

    public func select(_ tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        selectedTabID = tabID
        touch(tabID)
    }

    public func navigate(to url: URL) {
        guard let tab = selectedTab else { return }
        engine.load(url, in: tab.focusedPaneID)
        updatePane(tab.focusedPaneID) { $0.url = url }
        scheduleSave()
    }

    public func goBack() { selectedTab.map { engine.goBack(in: $0.focusedPaneID) } }
    public func goForward() { selectedTab.map { engine.goForward(in: $0.focusedPaneID) } }
    public func reload() { selectedTab.map { engine.reload(paneID: $0.focusedPaneID) } }
    public func stopLoading() { selectedTab.map { engine.stopLoading(paneID: $0.focusedPaneID) } }

    // MARK: - Surfaces

    /// Creates the web view for a pane on first activation, and not before (6.2).
    ///
    /// The Space is resolved from the tab, not from the active selection, so a
    /// view can never be built against the wrong data store.
    public func surface(for tab: Tab) -> AnyWebSurface? {
        guard let space = spaces.first(where: { $0.id == tab.spaceID }) else {
            Log.store.error("no space for tab \(tab.id, privacy: .public); refusing to render")
            return nil
        }
        return engine.surface(for: tab.focusedPane, in: space)
    }

    public func runtime(for paneID: UUID) -> PaneRuntime {
        if let existing = runtimes[paneID] { return existing }
        let runtime = PaneRuntime(paneID: paneID)
        runtimes[paneID] = runtime
        return runtime
    }

    public var liveWebViewCount: Int { engine.liveViewCount() }

    /// Approach zero CPU while the window is not visible (6.3).
    public func setOccluded(_ occluded: Bool) {
        isOccluded = occluded
        if let engine = engine as? WebKitEngine {
            engine.setOccluded(occluded)
        }
        // The sweep timer stops entirely rather than firing into a hidden
        // window and doing nothing (6.3).
        if occluded {
            stopSweep()
            flushSave()
        } else {
            startSweep()
        }
    }

    // MARK: - Mutation helpers

    func touch(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].lastAccessedAt = clock.now
        scheduleSave()
    }

    func updatePane(_ paneID: UUID, _ mutate: (inout Pane) -> Void) {
        guard let index = tabs.firstIndex(where: { tab in
            tab.panes.contains { $0.id == paneID }
        }) else { return }
        tabs[index].updatePane(paneID, mutate)
    }

    func tabID(owning paneID: UUID) -> UUID? {
        tabs.first { $0.panes.contains { $0.id == paneID } }?.id
    }

    // MARK: - Persistence

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [saveDebounce] in
            try? await Task.sleep(for: saveDebounce)
            guard !Task.isCancelled else { return }
            await self.performSave()
        }
    }

    public func flushSave() {
        saveTask?.cancel()
        saveTask = Task { await self.performSave() }
    }

    private func performSave() async {
        let snapshot = tabs
        do {
            try await repository.save(snapshot)
        } catch {
            Log.store.error("tab save failed: \(String(describing: error))")
        }
    }
}

// MARK: - WebEngineDelegate

extension TabStore: WebEngineDelegate {

    public func paneDidUpdate(_ paneID: UUID, snapshot: PaneSnapshot) {
        // Volatile state goes to the runtime object only, so a progress tick
        // never invalidates the sidebar.
        runtime(for: paneID).apply(snapshot)

        // Durable state goes to the model, and only when it actually changed —
        // an unconditional write here would redraw the tab list on every tick.
        guard let tabID = tabID(owning: paneID),
              let index = tabs.firstIndex(where: { $0.id == tabID })
        else { return }

        var didChange = false
        tabs[index].updatePane(paneID) { pane in
            if let url = snapshot.url, url != pane.url {
                pane.url = url
                didChange = true
            }
            if !snapshot.title.isEmpty, snapshot.title != pane.title {
                pane.title = snapshot.title
                didChange = true
            }
        }
        if didChange { scheduleSave() }

        // Record the visit once the page has a title and has stopped loading,
        // so history holds the settled title rather than an intermediate one.
        if didChange, !snapshot.isLoading, let url = snapshot.url, !snapshot.title.isEmpty {
            recordVisit(url: url, title: snapshot.title)
        }
    }

    public func paneDidLoadFavicon(_ paneID: UUID, data: Data?) {
        guard let data,
              let tabID = tabID(owning: paneID),
              let index = tabs.firstIndex(where: { $0.id == tabID })
        else { return }

        var didChange = false
        tabs[index].updatePane(paneID) { pane in
            if pane.faviconData != data {
                pane.faviconData = data
                didChange = true
            }
        }
        if didChange { scheduleSave() }
    }

    public func paneRequestedNewTab(url: URL) {
        newTab(url: url)
    }

    public func paneContentProcessDidTerminate(_ paneID: UUID) {
        // The engine already restarted the page. Nothing to do but note it —
        // the user should not see anything beyond a brief reload.
        Log.store.notice("recovered pane \(paneID, privacy: .public) after process termination")
    }
}
