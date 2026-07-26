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

    // Sidebar collapse/width, the collapsed-Pinned set, and the sheet flags used
    // to live here. They are per-*window*, not per-app — see `WindowState`.

    /// The search engine free-text queries go to (non-spec: user-requested).
    /// Persisted to `UserDefaults` as JSON, like the other window preferences —
    /// it is a user choice, not schema-bound user data.
    public var searchEngine: SearchEngine = Preferences.loadSearchEngine() {
        didSet { Preferences.save(searchEngine) }
    }

    /// What a brand-new tab opens to (non-spec: user-requested). Persisted
    /// alongside `searchEngine`.
    public var newTabBehavior: NewTabBehavior = Preferences.loadNewTabBehavior() {
        didSet { Preferences.save(newTabBehavior) }
    }

    /// The URL a `newTab()` with no explicit destination lands on, derived from
    /// `newTabBehavior` and (for the search-engine case) `searchEngine`.
    public var resolvedNewTabURL: URL {
        newTabBehavior.resolvedURL(searchEngine: searchEngine)
    }

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

    /// Sidebar folders across every Space; partitioned in memory by the active
    /// Space, like tabs (non-spec: user-requested). See `TabStore+Folders`.
    public internal(set) var folders: [Folder] = []

    @ObservationIgnored let engine: any WebEngine
    @ObservationIgnored let repository: any TabRepository
    @ObservationIgnored let spaceRepository: (any SpaceRepository)?
    @ObservationIgnored let historyRepository: (any HistoryRepository)?
    @ObservationIgnored let archiveRepository: (any ArchiveRepository)?
    @ObservationIgnored let folderRepository: (any FolderRepository)?
    @ObservationIgnored let clock: any Clock

    /// How long an unpinned tab may sit idle before it is auto-archived. "Never"
    /// disables the sweep (4.3). Persisted to `UserDefaults` like the other
    /// preferences; the next sweep pass picks up a change.
    public var idleWindow: IdleWindow = Preferences.loadIdleWindow() {
        didSet { Preferences.save(idleWindow) }
    }

    @ObservationIgnored private var hasRestored = false
    @ObservationIgnored var sweepTask: Task<Void, Never>?
    @ObservationIgnored var isOccluded = false

    /// Refreshed when the command bar opens, so keystrokes never hit the disk.
    @ObservationIgnored var cachedHistory: [HistoryEntry] = []
    @ObservationIgnored var cachedArchive: [ArchivedTab] = []

    /// Tabs closed by hand (Cmd+W), newest last, for Cmd+Shift+T. Distinct from
    /// the sweep's archive: the sweep never hard-closes and has its own recovery
    /// path (4.3), whereas a deliberate close needs an immediate one-key undo.
    /// In memory only — a reopen is a "just now" affordance, not session state.
    @ObservationIgnored var recentlyClosed: [Tab] = []
    /// Bound so a long session cannot grow this without limit.
    @ObservationIgnored static let recentlyClosedLimit = 25

    /// Per-pane URL awaiting a history record — set when a navigation starts (or
    /// its URL changes) and cleared once the settled title is written. Lets
    /// history recording survive the title and `isLoading` arriving in separate
    /// snapshots. See `recordVisitIfSettled`.
    @ObservationIgnored private var pendingHistoryURL: [UUID: URL] = [:]
    @ObservationIgnored var runtimes: [UUID: PaneRuntime] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Switching back to a Space should land where you left it.
    @ObservationIgnored var lastSelectedTabBySpace: [UUID: UUID] = [:]

    /// Set by `AppEnvironment` when the extensions flag is on (M7, 7.3b). The
    /// Store calls its tab-lifecycle hooks so each Space's controller can fire
    /// the matching WebExtensions events. `nil` when extensions are off, and the
    /// conformance to `ExtensionTabModel` (TabStore+Extensions.swift) is inert.
    @ObservationIgnored public weak var extensionHost: (any ExtensionHost)?

    /// Bumped whenever an extension updates its toolbar action (M7, 7.5a).
    /// `AppEnvironment` wires the host's `onActionsChanged` to increment this, so
    /// a SwiftUI view that reads it re-renders and re-queries
    /// `ExtensionsService.actions(in:)`. It carries no action data itself — it is
    /// purely an observation trigger, so the WebKit-free values stay in the
    /// service.
    public internal(set) var extensionActionsToken: Int = 0

    /// Extension permission prompts awaiting the user's decision (M7, 7.5c),
    /// presented one at a time by the UI as a sheet. `AppEnvironment` appends to
    /// this when the host surfaces a request; the values are WebKit-free.
    public internal(set) var pendingPermissionRequests: [PermissionRequest] = []

    /// Answers a pending permission prompt (7.5c). Forwards the decision to the
    /// host — which grants and persists on allow — and drops it from the queue.
    public func resolvePermissionRequest(_ id: UUID, allow: Bool) {
        extensionHost?.resolvePermission(id: id, allow: allow)
        pendingPermissionRequests.removeAll { $0.id == id }
    }

    /// Runs once at the end of `restore()`, after Spaces and tabs are loaded.
    /// `AppEnvironment` uses it to re-load enabled extensions (7.4), which needs
    /// the restored Spaces to exist first.
    @ObservationIgnored public var afterRestore: (@MainActor () async -> Void)?

    /// Opens a URL in the Little Arc floating panel. Injected by the app layer,
    /// which owns the panel; `nil` (and inert) until then. Used by the link
    /// context-menu action "Open in Little Chord" (non-spec: user-requested).
    @ObservationIgnored public var littleArcPresenter: (@MainActor (URL) -> Void)?

    /// Shows (non-nil) or dismisses (nil) the ⌘-hover Peek preview. Injected by
    /// the app layer, which owns the preview panel; inert until then.
    @ObservationIgnored public var peekPresenter: (@MainActor (URL?) -> Void)?

    /// Tab state is written debounced and coalesced, never per navigation (6.5).
    @ObservationIgnored private let saveDebounce: Duration = .seconds(2)

    public static let defaultNewTabURL = URL(string: "https://www.google.com")!

    public init(
        engine: any WebEngine,
        repository: any TabRepository,
        spaceRepository: (any SpaceRepository)? = nil,
        historyRepository: (any HistoryRepository)? = nil,
        archiveRepository: (any ArchiveRepository)? = nil,
        folderRepository: (any FolderRepository)? = nil,
        clock: any Clock
    ) {
        self.engine = engine
        self.repository = repository
        self.spaceRepository = spaceRepository
        self.historyRepository = historyRepository
        self.archiveRepository = archiveRepository
        self.folderRepository = folderRepository
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
            // Only folders whose Space still exists — a stray one would render
            // nowhere and orphan its tabs.
            let known = Set(spaces.map(\.id))
            folders = (try await folderRepository?.loadFolders() ?? [])
                .filter { known.contains($0.spaceID) }
        } catch {
            Log.store.error("folder restore failed: \(String(describing: error))")
            folders = []
        }

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
            newTab()
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

    /// - Parameter url: the destination, or `nil` to use the user's configured
    ///   new-tab behaviour (`resolvedNewTabURL`).
    public func newTab(url: URL? = nil) {
        guard let spaceID = activeSpace?.id else { return }
        let target = url ?? resolvedNewTabURL

        // Order is per-Space, so a new tab in one Space does not push another
        // Space's tabs down the list.
        let order = (visibleTabs.map(\.placement.order).max() ?? -1) + 1
        let tab = Tab(
            url: target, spaceID: spaceID, placement: .ephemeral(order: order), now: clock.now
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

        // Favourites and Pinned tabs are not removed by a close (Cmd+W) — Arc
        // keeps them in the sidebar. Closing instead unloads the live view,
        // leaving the entry in place; a Pinned tab also returns to its home URL.
        guard tabs[index].placement.isEphemeral else {
            unloadTab(at: index)
            return
        }

        // Remember it for Cmd+Shift+T before the panes are torn down, so the
        // reopened tab carries its URLs, title, favicon, and pinned placement.
        recentlyClosed.append(tabs[index])
        if recentlyClosed.count > Self.recentlyClosedLimit { recentlyClosed.removeFirst() }

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

    /// Closes a favourite or Pinned tab without removing it: the live view is
    /// torn down and the sidebar entry stays.
    ///
    /// A favourite keeps its current page — its state is captured first, so
    /// reopening restores where it was. A Pinned tab is reset to the URL it was
    /// pinned at, so reopening it lands at its home rather than wherever it had
    /// drifted. Either way the sidebar keeps its favicon rather than flashing to
    /// a bare globe until the next load.
    private func unloadTab(at index: Int) {
        let tabID = tabs[index].id

        // A Pinned tab is going home, so its state is discarded; a favourite
        // stays put, so its state is captured before the view is evicted.
        let isReturningHome = tabs[index].placement.isBookmarked
        if !isReturningHome { captureInteractionState(forTab: tabID) }

        for pane in tabs[index].panes {
            engine.evict(paneID: pane.id)
            runtimes[pane.id] = nil
        }
        forgetStateResolution(forPanes: tabs[index].panes.map(\.id))

        if isReturningHome, let home = tabs[index].placement.homeURL {
            // A fresh single pane at the home URL — a new pane id orphans the
            // stale interaction blob, which the next save prunes (6.5). The
            // favicon is carried over so the tab keeps its icon in the sidebar,
            // but only when it still matches the home origin: a favicon is
            // per-origin, and a tab that drifted cross-site would keep the wrong
            // one. The title comes along only when nothing drifted.
            let previous = tabs[index].focusedPane
            let sameOrigin = previous.url.host() == home.host()
            let pane = Pane(
                url: home,
                title: home == previous.url ? previous.title : "",
                faviconData: sameOrigin ? previous.faviconData : nil
            )
            tabs[index].panes = [pane]
            tabs[index].focusedPaneID = pane.id
            stateResolution[pane.id] = .resolved
        }

        // Move the selection off the unloaded tab, but leave it in the sidebar.
        if selectedTabID == tabID {
            if let next = visibleTabs.first(where: { $0.id != tabID }) {
                select(next.id)
            } else {
                selectedTabID = nil
                newTab()
            }
        }
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

        // Pinning captures the tab's current URL as its home — the URL
        // double-clicking the favourite returns it to. An existing home (from a
        // previous pin) is kept when re-pinning.
        let home = tabs[index].placement.homeURL ?? tabs[index].focusedPane.url
        tabs[index].placement = pinned
            ? .pinned(order: order, homeURL: home)
            : .ephemeral(order: order)
        scheduleSave()
    }

    public func pin(_ tabID: UUID) { setPinned(true, tabID: tabID) }
    public func unpin(_ tabID: UUID) { setPinned(false, tabID: tabID) }

    /// Turns a tab into an Arc-style *Pinned* tab, or back into a loose one
    /// (non-spec: user-requested). Pinning captures the tab's current focused
    /// URL as its home — the URL clicking the row returns it to. Like the
    /// favourites, Pinned tabs are exempt from the ephemeral sweep. Order is
    /// recomputed within the destination section so both lists stay dense.
    public func setBookmarked(_ bookmarked: Bool, tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[index].placement.isBookmarked != bookmarked
        else { return }

        let spaceID = tabs[index].spaceID
        let matches: (Tab) -> Bool = bookmarked
            ? { $0.placement.isBookmarked }
            : { $0.placement.isEphemeral }
        let order = tabs
            .filter { $0.spaceID == spaceID && matches($0) }
            .map(\.placement.order)
            .max()
            .map { $0 + 1 } ?? 0

        tabs[index].placement = bookmarked
            ? .bookmarked(order: order, homeURL: tabs[index].focusedPane.url)
            : .ephemeral(order: order)
        scheduleSave()
    }

    /// Replaces a favourite or Pinned tab's home with its current URL, so the
    /// page it is on now becomes the one it returns to (non-spec: user-requested).
    /// No-op for a loose tab, or when the home already matches.
    public func updatePinnedHome(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let current = tabs[index].focusedPane.url

        switch tabs[index].placement {
        case .pinned(let order, let home) where home != current:
            tabs[index].placement = .pinned(order: order, homeURL: current)
        case .bookmarked(let order, let home) where home != current:
            tabs[index].placement = .bookmarked(order: order, homeURL: current)
        default:
            return
        }
        scheduleSave()
    }

    /// Navigates a favourite or Pinned tab back to the URL it was pinned at
    /// (4.1). No-op for a loose tab, a favourite with no recorded home, or a tab
    /// already sitting on its home URL.
    public func returnToPinnedHome(_ tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let home = tab.placement.homeURL,
              tab.focusedPane.url != home
        else { return }
        select(tabID)
        navigate(to: home)
    }

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

    /// Whether the tab's focused pane is muted (non-spec: user-requested).
    public func isMuted(_ tabID: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return false }
        return runtime(for: tab.focusedPaneID).isMuted
    }

    /// Toggles mute for every pane in the tab, so a split's audio is silenced as
    /// one. The engine keeps the state, surviving reload and eviction.
    public func toggleMute(_ tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        let target = !isMuted(tabID)
        for pane in tab.panes {
            engine.setMuted(target, paneID: pane.id)
            // Immediate UI feedback even when the pane has no live view to echo a
            // snapshot back; a live pane's snapshot confirms the same value.
            runtime(for: pane.id).isMuted = target
        }
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
        var urlChanged = false
        tabs[index].updatePane(paneID) { pane in
            if let url = snapshot.url, url != pane.url {
                pane.url = url
                didChange = true
                urlChanged = true
            }
            if !snapshot.title.isEmpty, snapshot.title != pane.title {
                pane.title = snapshot.title
                didChange = true
            }
        }
        if didChange { scheduleSave() }

        recordVisitIfSettled(
            paneID, snapshot: snapshot, urlChanged: urlChanged, spaceID: tabs[index].spaceID
        )
    }

    /// Records a history visit when a navigation settles, decoupled from the
    /// per-field `didChange` above.
    ///
    /// The engine publishes a fresh snapshot on every KVO change, so the title
    /// usually arrives while the page is still loading and `isLoading` flips to
    /// false in a *later* snapshot whose title already matches the model. Gating
    /// the record on "this snapshot changed something" therefore missed almost
    /// every real page load. Instead this tracks the load transition per pane and
    /// records once the page is idle and has a title — recording the pending URL
    /// when the title lands after the load finishes, and deduping so repeat idle
    /// snapshots do not inflate the visit count.
    private func recordVisitIfSettled(
        _ paneID: UUID, snapshot: PaneSnapshot, urlChanged: Bool, spaceID: UUID
    ) {
        guard let url = snapshot.url,
              let scheme = url.scheme, scheme == "http" || scheme == "https"
        else { return }

        // A new URL (fresh load or in-page navigation) reopens the record window
        // for this pane, so a settled title is written even when WebKit never
        // flipped `isLoading` for the navigation.
        if urlChanged { pendingHistoryURL[paneID] = url }

        if snapshot.isLoading {
            pendingHistoryURL[paneID] = url
            return
        }

        // Idle. Record only against the URL still awaiting one, so steady-state
        // snapshots (progress, focus) do not re-record the same page.
        guard pendingHistoryURL[paneID] == url, !snapshot.title.isEmpty else { return }
        recordVisit(url: url, title: snapshot.title, spaceID: spaceID)
        pendingHistoryURL[paneID] = nil
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

    public func paneRequestedLittleArc(url: URL) {
        // The Little Arc panel is owned by the app layer (AppDelegate), so the
        // store forwards through an injected presenter rather than depending on
        // UI. No-op until it is wired — the same shape as `afterRestore`.
        littleArcPresenter?(url)
    }

    public func paneRequestedPeek(url: URL?) {
        peekPresenter?(url)
    }

    public func paneContentProcessDidTerminate(_ paneID: UUID) {
        // The engine already restarted the page. Nothing to do but note it —
        // the user should not see anything beyond a brief reload.
        Log.store.notice("recovered pane \(paneID, privacy: .public) after process termination")
    }
}
