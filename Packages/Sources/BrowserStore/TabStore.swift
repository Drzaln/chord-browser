import BrowserCore
import BrowserEngine
import BrowserExtensions
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

    /// The sidebar tab currently being dragged, if any. Observed: it is what
    /// puts the content area's drop layer on screen (4.5).
    public internal(set) var draggingTabID: UUID?

    /// Signed progress of an in-flight swipe between Spaces, in `[-1, 1]` (4.2).
    /// Positive is toward the next Space (higher `sortIndex`). Observed: the
    /// sidebar blends its gradient toward the neighbour's as this moves. Volatile
    /// and never persisted — it is a gesture, not user data. See `TabStore+SpaceSwipe`.
    public internal(set) var spaceSwipeProgress: Double = 0

    /// Whether the sidebar is collapsed to icons (4.1).
    ///
    /// In the store rather than in a view because the menu command drives it
    /// too, and a `@State` in `RootView` is not reachable from `Commands`.
    /// Persisted to `UserDefaults`, not to SQLite: it is a window preference,
    /// not user data, and it has no place in a schema that carries migrations.
    public var isSidebarCollapsed: Bool = UserDefaults.standard.bool(forKey: "sidebar.collapsed") {
        didSet { UserDefaults.standard.set(isSidebarCollapsed, forKey: "sidebar.collapsed") }
    }

    /// The user-configured width of the sidebar, persisted in UserDefaults.
    public var sidebarWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "sidebar.width")
        return saved > 0 ? CGFloat(saved) : 240
    }() {
        didSet {
            UserDefaults.standard.set(Double(sidebarWidth), forKey: "sidebar.width")
        }
    }

    /// Whether the user is actively dragging to resize the sidebar.
    public var isSidebarResizing: Bool = false

    /// The Space whose appearance is being edited, if any. Ephemeral UI state
    /// kept here — not in the sidebar — so its editor sheet is presented from
    /// `RootView` and survives the sidebar collapsing (and auto-hiding) beneath
    /// it. Not persisted.
    public var editingSpaceID: UUID?

    /// The Space being deleted, if any. Ephemeral UI state kept here so its
    /// confirmation dialog is presented from RootView and survives the sidebar
    /// collapsing (and auto-hiding) beneath it. Not persisted.
    public var deletingSpaceID: UUID?

    /// Find-in-page (M6). See `TabStore+Find`.
    public var isFindBarVisible = false
    public var findText = ""
    /// `nil` until a non-empty query has been run, so an empty bar does not
    /// report "not found".
    public internal(set) var findFoundMatch: Bool?
    @ObservationIgnored var findTask: Task<Void, Never>?

    /// Which panes are still waiting on their stored `interactionState`.
    /// Deliberately observed: flipping a pane to `.resolved` is what re-renders
    /// the content view and lets its surface be built.
    var stateResolution: [UUID: StateResolution] = [:]

    @ObservationIgnored let engine: any WebEngine
    @ObservationIgnored let repository: any TabRepository
    @ObservationIgnored let spaceRepository: (any SpaceRepository)?
    @ObservationIgnored let historyRepository: (any HistoryRepository)?
    @ObservationIgnored let archiveRepository: (any ArchiveRepository)?
    @ObservationIgnored let clock: any Clock

    /// How long an unpinned tab may sit idle. User-configurable; "never" is
    /// allowed and disables the sweep (4.3).
    public var idleWindow: IdleWindow = .default

    @ObservationIgnored private var hasRestored = false
    @ObservationIgnored var sweepTask: Task<Void, Never>?
    @ObservationIgnored var isOccluded = false

    /// Refreshed when the command bar opens, so keystrokes never hit the disk.
    @ObservationIgnored var cachedHistory: [HistoryEntry] = []
    @ObservationIgnored var cachedArchive: [ArchivedTab] = []
    @ObservationIgnored var runtimes: [UUID: PaneRuntime] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Switching back to a Space should land where you left it.
    @ObservationIgnored var lastSelectedTabBySpace: [UUID: UUID] = [:]

    /// Set by `AppEnvironment` when the extensions flag is on (M7, 7.3b). The
    /// Store calls its tab-lifecycle hooks so each Space's controller can fire
    /// the matching WebExtensions events. `nil` when extensions are off, and the
    /// conformance to `ExtensionTabModel` (TabStore+Extensions.swift) is inert.
    @ObservationIgnored public weak var extensionHost: (any ExtensionHost)?

    /// Runs once at the end of `restore()`, after Spaces and tabs are loaded.
    /// `AppEnvironment` uses it to re-load enabled extensions (7.4), which needs
    /// the restored Spaces to exist first.
    @ObservationIgnored public var afterRestore: (@MainActor () async -> Void)?

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
        // Exactly once per store. A second view calling this would reload the
        // tab list over live state — and if that load failed it would replace
        // a working session with an empty one, then persist the emptiness.
        guard !hasRestored else {
            Log.store.notice("restore already ran; ignoring")
            return
        }
        hasRestored = true

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
            // Only the tab about to be shown has its blob read. The rest are
            // read if and when they are activated (6.5).
            if let selectedTabID { resolveInteractionState(forTab: selectedTabID) }
        }

        startSweep()

        // Extensions load after the Spaces they belong to exist (7.4).
        await afterRestore?()
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
        // A brand-new pane definitionally has nothing stored, so mark it
        // resolved rather than spending a disk read to discover that — and to
        // avoid withholding its surface for a frame.
        for pane in tab.panes { stateResolution[pane.id] = .resolved }
        let previous = selectedTabID
        selectedTabID = tab.id
        extensionHost?.extensionTabDidOpen(tab.id, inSpace: spaceID)
        extensionHost?.extensionTabDidActivate(tab.id, previous: previous, inSpace: spaceID)
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

        let fromSpaceID = tabs[index].spaceID
        for pane in tabs[index].panes {
            engine.evict(paneID: pane.id)
        }

        let order = (tabs.filter { $0.spaceID == spaceID }.map(\.placement.order).max() ?? -1) + 1
        tabs[index].spaceID = spaceID
        tabs[index].placement = tabs[index].placement.withOrder(order)

        // To each Space's extensions this reads as the tab leaving one window
        // and arriving in another (7.4).
        extensionHost?.extensionTabDidClose(tabID, inSpace: fromSpaceID)
        extensionHost?.extensionTabDidOpen(tabID, inSpace: spaceID)

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
        forgetStateResolution(forPanes: tabs[index].panes.map(\.id))
        let closedSpaceID = tabs[index].spaceID
        let neighbours = visibleTabs
        let closedPosition = neighbours.firstIndex { $0.id == tabID }
        tabs.remove(at: index)
        extensionHost?.extensionTabDidClose(tabID, inSpace: closedSpaceID)

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
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        let outgoing = selectedTabID

        // Capture before the switch, while the outgoing tab's view is still
        // live. This is the "persist on deactivation" rule in 3.2 — the only
        // point at which a tab the user merely switched away from gets its
        // state written.
        if let outgoing, outgoing != tabID {
            captureInteractionState(forTab: outgoing)
        }

        selectedTabID = tabID
        resolveInteractionState(forTab: tabID)
        touch(tabID)

        // `previous` is the prior active tab only when it was in the same Space;
        // the previousActiveTab argument to the WebExtensions event must belong
        // to the same window (Space), which our per-Space controllers require.
        let previousInSameSpace =
            outgoing.flatMap { id in tabs.first(where: { $0.id == id }) }
            .flatMap { $0.spaceID == tab.spaceID ? $0.id : nil }
        extensionHost?.extensionTabDidActivate(
            tabID, previous: previousInSameSpace, inSpace: tab.spaceID
        )
    }

    public func navigate(to url: URL) {
        guard let tab = selectedTab else { return }
        engine.load(url, in: tab.focusedPaneID)
        updatePane(tab.focusedPaneID) { $0.url = url }
        scheduleSave()
    }

    /// Prints the focused pane's page (M6). Searches the focused pane, like find
    /// (4.1): in a split, Cmd+P prints the pane you are reading.
    public func printSelectedPane() {
        selectedTab.map { engine.printPane(paneID: $0.focusedPaneID) }
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
        surface(for: tab.focusedPane, in: tab)
    }

    /// Per *pane*, because split view renders every pane at once.
    ///
    /// The gate below must be checked for the pane being rendered, not for the
    /// tab's focused one. While they were always the same — one pane per tab —
    /// gating on the focused pane looked correct; with a second pane on screen
    /// it would build that pane's view before its state had been read and throw
    /// the restore away.
    public func surface(for pane: Pane, in tab: Tab) -> AnyWebSurface? {
        guard let space = spaces.first(where: { $0.id == tab.spaceID }) else {
            Log.store.error("no space for tab \(tab.id, privacy: .public); refusing to render")
            return nil
        }

        // Withhold the surface until the pane's stored state has been read.
        // Building the view first would load the bare URL, and seeding state
        // into a live view afterwards would throw that load away and fight the
        // user for the scroll position.
        guard !isAwaitingInteractionState(pane.id) else { return nil }

        return engine.surface(for: pane, in: space)
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
            // A hidden window is the last safe moment to capture state: the
            // machine may sleep or the app be killed without another chance.
            captureAllInteractionState()
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

    /// `flushSave` that can be awaited, for the quit path.
    public func flushSaveAndWait() async {
        saveTask?.cancel()
        await performSave()
    }

    private func performSave() async {
        let snapshot = tabs
        do {
            try await repository.save(snapshot)
        } catch {
            Log.store.error("tab save failed: \(String(describing: error))")
        }

        // Reclaim state for panes that no longer exist. Nothing else does this:
        // the blob table has no foreign key to `pane`, on purpose, so a closed
        // tab's state would otherwise sit on disk forever (6.5).
        let living = Set(snapshot.flatMap { $0.panes.map(\.id) })
        do {
            try await repository.pruneInteractionStates(keeping: living)
        } catch {
            Log.store.error("interaction state prune failed: \(String(describing: error))")
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
