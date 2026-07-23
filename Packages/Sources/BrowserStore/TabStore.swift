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
    public private(set) var tabs: [Tab] = []
    public private(set) var spaces: [Space] = []
    public private(set) var activeSpaceID: UUID?
    public var selectedTabID: UUID?

    @ObservationIgnored private let engine: any WebEngine
    @ObservationIgnored private let repository: any TabRepository
    @ObservationIgnored private let spaceRepository: (any SpaceRepository)?
    @ObservationIgnored private let clock: any Clock
    @ObservationIgnored private var runtimes: [UUID: PaneRuntime] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Switching back to a Space should land where you left it.
    @ObservationIgnored private var lastSelectedTabBySpace: [UUID: UUID] = [:]

    /// Tab state is written debounced and coalesced, never per navigation (6.5).
    @ObservationIgnored private let saveDebounce: Duration = .seconds(2)

    public static let defaultNewTabURL = URL(string: "https://duckduckgo.com")!

    public init(
        engine: any WebEngine,
        repository: any TabRepository,
        spaceRepository: (any SpaceRepository)? = nil,
        clock: any Clock
    ) {
        self.engine = engine
        self.repository = repository
        self.spaceRepository = spaceRepository
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

    private func persistSpaces() async {
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
        if let engine = engine as? WebKitEngine {
            engine.setOccluded(occluded)
        }
        if occluded { flushSave() }
    }

    // MARK: - Mutation helpers

    private func touch(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].lastAccessedAt = clock.now
        scheduleSave()
    }

    private func updatePane(_ paneID: UUID, _ mutate: (inout Pane) -> Void) {
        guard let index = tabs.firstIndex(where: { tab in
            tab.panes.contains { $0.id == paneID }
        }) else { return }
        tabs[index].updatePane(paneID, mutate)
    }

    private func tabID(owning paneID: UUID) -> UUID? {
        tabs.first { $0.panes.contains { $0.id == paneID } }?.id
    }

    // MARK: - Persistence

    private func scheduleSave() {
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
