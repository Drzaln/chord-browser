import BrowserCore
import BrowserEngine
import BrowserExtensions
import BrowserLogging
import BrowserSecrets
import Foundation
import Observation
import os

enum Log {
    static let store = AppLog.category("store")
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

    /// The window every store has: the app's first, and the only one that exists
    /// until a second is opened. Owned here rather than by the scene so that the
    /// store always has somewhere to put a selection, and so a headless test does
    /// not have to build a window before it can select a tab.
    public let primaryWindow: WindowState

    /// Every window looking at this store, the primary first. Weak: a window is
    /// owned by its scene, and a closed one must not be kept alive by this list.
    ///
    /// The store needs to know them because closing a tab in one window has to
    /// leave the *others* pointing at something real — see `reconcileWindows`.
    @ObservationIgnored private var secondaryWindows: [WeakWindow] = []

    /// The primary plus every live secondary, in registration order.
    public var windows: [WindowState] {
        [primaryWindow] + secondaryWindows.compactMap(\.value)
    }

    /// Whether the primary window has been handed to a scene yet.
    @ObservationIgnored var hasClaimedPrimary = false

    /// Set by ⌘⇧N and consumed by the next `claimWindow()`. See
    /// `TabStore+Private.swift` for why the channel is a latch rather than a
    /// `WindowGroup(id:for:)` presentation value.
    @ObservationIgnored var pendingWindowKind: WindowKind?

    /// Vends the state for a newly-opened scene: the primary window the first
    /// time, a fresh registered one after that.
    ///
    /// `WindowGroup` builds its content for every window and gives no say in
    /// which is "first", so the scene asks rather than decides. Idempotent per
    /// scene because the caller holds the result in `@State`.
    public func claimWindow() -> WindowState {
        let kind = takeWindowKind()
        guard hasClaimedPrimary else {
            hasClaimedPrimary = true
            return primaryWindow
        }

        // A private window (⌘⇧N) is a different thing from here on: it makes its
        // own throwaway Space, opens a tab in it, and takes no saved layout —
        // there is never one to take, since a private window is not persisted.
        if case .private(let url) = kind {
            let space = makePrivateSpace()
            spaces.append(space)  // deliberately NOT persisted — see visibleSpaces
            let window = WindowState(isPrivate: true)
            window.activeSpaceID = space.id
            window.privateSpaceID = space.id
            register(window)
            newTab(url: url, in: window)
            return window
        }

        let window = WindowState()
        // A new window opens on the same Space as the one that spawned it, which
        // is what every browser does with Cmd+N.
        window.activeSpaceID = primaryWindow.activeSpaceID ?? spaces.first?.id
        register(window)
        // A scene macOS restores *after* `restore()` gets its saved layout (v9);
        // one opened by the user (or claiming before restore, when the queue is
        // empty) gets its *own* selection via `reconcile` — never one already on
        // screen, which would leave one of the two windows blank. An early claim
        // holding nil is repaired by `applyRestoredLayouts` when restore runs.
        if let layout = takeNextPendingLayout(), applyLayout(layout, to: window) {
            if let selected = window.selectedTabID {
                resolveInteractionState(forTab: selected)
            }
        } else {
            reconcile(window)
        }
        // A new window changes the saved layout set (v9).
        scheduleSave()
        return window
    }

    /// Adds a window opened after launch. The primary is always present and must
    /// not be registered again.
    public func register(_ window: WindowState) {
        guard window !== primaryWindow else { return }
        guard !secondaryWindows.contains(where: { $0.value === window }) else { return }
        secondaryWindows.append(WeakWindow(window))
    }

    /// Drops a closed window, and compacts any that were deallocated.
    public func unregister(_ window: WindowState) {
        secondaryWindows.removeAll { $0.value == nil || $0.value === window }
        // Closing a private window ends its session. The window is out of the
        // registry *first*, on purpose: the teardown's `reconcileWindows()`
        // would otherwise re-home a window that is on its way out onto a Space
        // that is on its way out.
        if let privateSpaceID = window.privateSpaceID {
            tearDownPrivateSession(privateSpaceID)
        }
        // A closed window changes the saved layout set (v9): the layout snapshot
        // is rebuilt from the windows that remain.
        scheduleSave()
    }

    /// The window the user most recently focused. Weak: a closed window must not
    /// be kept alive here, and a nil (closed or never-set) one falls back to the
    /// primary in `focusedWindow`.
    @ObservationIgnored private weak var lastFocusedWindow: WindowState?

    /// The window that app-opened URLs and a promoted Little Arc tab land in: the
    /// one the user last focused, or the primary when none has been (a URL that
    /// opens the app cold). This is why those two used to always hit the primary —
    /// nothing tracked which window was current.
    public var focusedWindow: WindowState {
        lastFocusedWindow ?? primaryWindow
    }

    /// Where a URL handed over by the *OS* lands: the focused window unless it
    /// is private, and then the first normal one.
    ///
    /// A link opened from Mail or Slack has nothing to do with the private
    /// session that happens to be in front, and silently joining it would put
    /// that page beyond history, restore, and the vault without the user having
    /// asked for any of that.
    public var focusedNonPrivateWindow: WindowState {
        let focused = focusedWindow
        guard focused.isPrivate else { return focused }
        return windows.first { !$0.isPrivate } ?? primaryWindow
    }

    /// Records that a window became key, so `focusedWindow` follows the user's
    /// current one. Each window reports this as its scene becomes key.
    public func windowDidBecomeFocused(_ window: WindowState) {
        lastFocusedWindow = window
    }

    /// The sidebar tab currently being dragged, if any. Observed: it is what
    /// puts the content area's drop layer on screen (4.5).
    public internal(set) var draggingTabID: UUID?

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

    /// The Little Arc / Peek panel's size, as the user last left it (non-spec:
    /// user-requested). `nil` until the first resize; the controller falls back
    /// to the panel's built-in default.
    public var littleArcPanelSize: CGSize? {
        get { Preferences.loadLittleArcPanelSize(preferenceStore) }
        set {
            guard let newValue else { return }
            Preferences.save(littleArcPanelSize: newValue, to: preferenceStore)
        }
    }

    /// The User-Agent every web view presents (non-spec: user-requested).
    /// Persisted like the other preferences; the setter pushes it to the engine
    /// so live views (on their next load) and new views both pick it up.
    public var userAgent: UserAgentPreference = Preferences.loadUserAgent() {
        didSet {
            Preferences.save(userAgent)
            pushUserAgent()
        }
    }

    /// Per-domain User-Agent overrides (§9.6). These beat `userAgent` for the
    /// sites they name, including a per-domain `.default` that turns a global
    /// spoof back off — the Google Meet case.
    public var userAgentOverrides: [UserAgentOverride] = Preferences.loadUserAgentOverrides() {
        didSet {
            Preferences.save(userAgentOverrides, to: preferenceStore)
            pushUserAgent()
        }
    }

    /// Hands the engine the whole policy at once. It resolves which UA a
    /// navigation gets, because it is the only layer that sees the URL.
    func pushUserAgent() {
        engine.setUserAgent(userAgent, overrides: userAgentOverrides)
    }

    /// Adds or replaces a rule, normalising what the user typed. Returns false
    /// when there is no usable domain in it, so the UI can say so rather than
    /// storing a rule that matches nothing.
    @discardableResult
    public func setUserAgentOverride(
        domain: String, preference: UserAgentPreference
    ) -> Bool {
        guard let normalised = UserAgentRules.normalise(domain) else { return false }
        var updated = userAgentOverrides.filter { $0.domain != normalised }
        updated.append(UserAgentOverride(domain: normalised, preference: preference))
        userAgentOverrides = updated.sorted { $0.domain < $1.domain }
        return true
    }

    public func removeUserAgentOverride(domain: String) {
        userAgentOverrides.removeAll { $0.domain == domain }
    }

    /// The URL a `newTab()` with no explicit destination lands on, derived from
    /// `newTabBehavior` and (for the search-engine case) `searchEngine`.
    public var resolvedNewTabURL: URL {
        newTabBehavior.resolvedURL(searchEngine: searchEngine)
    }

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
    @ObservationIgnored let windowLayoutRepository: (any WindowLayoutRepository)?
    @ObservationIgnored let clock: any Clock

    /// Layouts loaded at restore for windows that have not claimed yet, primary
    /// dropped (it is applied directly). Each secondary scene pops the next one in
    /// `claimWindow`; when it runs dry, later windows reconcile as before. Cleared
    /// as it drains so a late window never re-applies a stale layout.
    @ObservationIgnored var pendingWindowLayouts: [WindowLayout] = []

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

    /// The password vault (V4), when one is wired. Optional because the
    /// subsystem is built in phases and the app does not wire it until the UI
    /// phases land — a nil vault simply offers nothing, which is what every
    /// caller already handles.
    @ObservationIgnored public var vault: CredentialVault?

    /// Which origins may hold a credential (`.strict` in the app — see
    /// `CredentialOrigin.Policy`). Set alongside `vault`.
    @ObservationIgnored public var loginOriginPolicy: CredentialOrigin.Policy = .strict

    /// Authenticates the user before a stored password is shown as text (V6).
    /// Injected so tests do not need a fingerprint; `nil` means reveal is simply
    /// unavailable, which is the safe way to be missing.
    @ObservationIgnored public var authenticator: (any VaultAuthenticator)?

    /// How long the vault stays unlocked when idle (V7). Persisted through
    /// `preferenceStore`, which is injectable purely so a test can change this
    /// without writing to the real `~/Library/Preferences`.
    public var vaultLockTimeout: VaultLockTimeout = Preferences.loadVaultLockTimeout() {
        didSet {
            Preferences.save(vaultLockTimeout, to: preferenceStore)
            refreshVaultLock()
        }
    }

    /// Where `vaultLockTimeout` is persisted. `UserDefaults` in the app.
    @ObservationIgnored public var preferenceStore: any PreferenceStore = UserDefaults.standard

    /// Whether the vault is locked right now (V7). Observed, because the fill
    /// button and Settings both show it.
    ///
    /// **Evaluated lazily**, at every vault touchpoint and whenever the UI asks
    /// (`refreshVaultLock()`), rather than by a timer: a repeating timer that
    /// writes observable state would redraw the chrome forever for a value that
    /// only matters at the moment someone uses the vault (§6.4).
    public internal(set) var isVaultLocked: Bool = true

    /// When the vault was last unlocked, and when it was last *used*. Any use
    /// restarts the idle clock; without one, the unlock itself does. Not
    /// observed — they are inputs to `isVaultLocked`, which is.
    @ObservationIgnored var vaultUnlockedAt: Date?
    @ObservationIgnored var vaultLastActivity: Date?

    /// An offer to save a submitted login, awaiting an answer (V5). Observed by
    /// the save bar.
    public internal(set) var pendingCredentialSave: CredentialSavePrompt?

    /// The passwords behind the pending offers, kept **out** of the observable
    /// model on purpose: `pendingCredentialSave` is bound into view bodies and
    /// would otherwise carry a plaintext secret into every description of this
    /// store. Cleared whenever a prompt is answered or dropped.
    @ObservationIgnored var pendingCredentialSecrets: [UUID: String] = [:]
    /// Which Space each pending offer was captured in.
    @ObservationIgnored var pendingCredentialSpaces: [UUID: UUID?] = [:]

    /// Recomputes which saved credentials could fill the page a pane is showing,
    /// and publishes the answer on its runtime.
    func refreshFillableCredentials(for paneID: UUID) {
        guard vault != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            let spaceID = self.spaceID(forPane: paneID)
            let matches = await self.credentials(forPane: paneID, inSpace: spaceID)
            self.runtime(for: paneID).fillableCredentials = matches
        }
    }

    /// The last username submitted per origin, for pairing the two halves of a
    /// multi-step login (V6). In memory only and never persisted: it is a
    /// half-finished sign-in, not user data, and it should not outlive the
    /// session that was typing it.
    @ObservationIgnored var lastSubmittedUsernames: [String: String] = [:]

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

    /// Camera/mic/notification prompts awaiting the user's decision (non-spec:
    /// user-requested), presented one at a time by the UI as a sheet. Populated
    /// by `requestSitePermission` when a site has no remembered decision.
    public internal(set) var pendingSitePermissionPrompts: [SitePermissionPrompt] = []

    /// Remembers per-Space, per-origin decisions so a site is asked once. Injected
    /// by `AppEnvironment`; when `nil` the store falls back to prompting every
    /// time (no persistence), which is safe if less convenient.
    @ObservationIgnored public var sitePermissions: (any SitePermissionsRepository)?

    /// The awaiting request continuations, keyed by prompt id, resumed when the
    /// sheet is answered (or dismissed, treated as a denial).
    @ObservationIgnored private var sitePermissionContinuations:
        [UUID: CheckedContinuation<Bool, Never>] = [:]

    /// The shared path behind `getUserMedia` and `Notification.requestPermission()`:
    /// honour a remembered decision for the pane's Space, else prompt once and let
    /// `resolveSitePermission` persist the answer and resume us.
    private func requestSitePermission(_ prompt: SitePermissionPrompt) async -> Bool {
        if let spaceID = spaceID(forPane: prompt.paneID) {
            let stored =
                (try? await sitePermissions?.decisions(forOrigin: prompt.origin, spaceID: spaceID))
                ?? [:]
            let undecided = prompt.kinds.filter { stored[$0] == nil }
            if undecided.isEmpty {
                return prompt.kinds.allSatisfy { stored[$0] == .granted }
            }
        }
        return await withCheckedContinuation { continuation in
            sitePermissionContinuations[prompt.id] = continuation
            pendingSitePermissionPrompts.append(prompt)
        }
    }

    /// Answers a pending prompt: resumes the awaiting page, persists the choice
    /// for the pane's Space and every kind the prompt covered, and — for a
    /// notification grant — requests OS authorization as the delivery backstop.
    public func resolveSitePermission(_ id: UUID, allow: Bool) {
        guard let prompt = pendingSitePermissionPrompts.first(where: { $0.id == id })
        else { return }
        pendingSitePermissionPrompts.removeAll { $0.id == id }
        if let continuation = sitePermissionContinuations.removeValue(forKey: id) {
            continuation.resume(returning: allow)
        }
        // A web notification only reaches Notification Center if the app itself
        // is OS-authorized; ask for that the first time a site is allowed.
        if allow, prompt.kinds.contains(.notification) {
            Task { _ = await notificationPermissionRequester?() }
        }
        guard let sitePermissions, let spaceID = spaceID(forPane: prompt.paneID) else { return }
        // The page gets its answer either way; a private session just does not
        // remember having given one, so the next private window asks again.
        guard !isPrivate(spaceID: spaceID) else { return }
        let decision: SitePermissionDecision = allow ? .granted : .denied
        Task {
            for kind in prompt.kinds {
                try? await sitePermissions.setDecision(
                    decision, forOrigin: prompt.origin, spaceID: spaceID, kind: kind
                )
            }
            await refreshSitePermissions()
        }
    }

    /// The Space a pane lives in, for scoping its decision. `nil` if the
    /// pane is not in any tab (it always is for a live `getUserMedia`, but the
    /// caller degrades to prompt-without-persist rather than crash).
    func spaceID(forPane paneID: UUID?) -> UUID? {
        guard let paneID else { return nil }
        return tabs.first { $0.panes.contains { $0.id == paneID } }?.spaceID
    }

    // MARK: - Site permissions (settings management)

    /// Every remembered camera/mic decision, for the Privacy settings list.
    /// Loaded from the repository via `refreshSitePermissions`.
    public internal(set) var sitePermissionRecords: [SitePermissionRecord] = []

    /// Reloads `sitePermissionRecords` from the repository. Called after a
    /// grant/deny and when the settings panel appears.
    public func refreshSitePermissions() async {
        sitePermissionRecords = (try? await sitePermissions?.all()) ?? []
    }

    /// Forgets every device decision for one origin in one Space, so the site is
    /// asked again next time. Used by the settings "reset site" action.
    public func revokeSitePermission(origin: String, spaceID: UUID) {
        guard let sitePermissions else { return }
        Task {
            try? await sitePermissions.revoke(origin: origin, spaceID: spaceID)
            await refreshSitePermissions()
        }
    }

    /// Runs once at the end of `restore()`, after Spaces and tabs are loaded.
    /// `AppEnvironment` uses it to re-load enabled extensions (7.4), which needs
    /// the restored Spaces to exist first.
    @ObservationIgnored public var afterRestore: (@MainActor () async -> Void)?

    /// Opens a URL in the Little Arc floating panel. Injected by the app layer,
    /// which owns the panel; `nil` (and inert) until then. Used by the link
    /// context-menu action "Open in Little Chord" (non-spec: user-requested).
    @ObservationIgnored public var littleArcPresenter: (@MainActor (URL) -> Void)?

    /// Opens a new browser window. Set by the scene layer, which is the only
    /// place SwiftUI's `openWindow` exists; the store only ever asks.
    @ObservationIgnored public var privateWindowPresenter: (@MainActor () -> Void)?

    /// Presents the Peek panel for a link clicked in a favourite/pinned tab
    /// (non-spec: user-requested). Injected by the app layer, which owns the
    /// panel; inert until then. Takes the URL and the Space the click happened
    /// in, so the panel surfaces already logged in to the same Space.
    @ObservationIgnored public var peekPresenter: (@MainActor (URL, UUID) -> Void)?

    /// Posts a web notification to macOS Notification Center (non-spec:
    /// user-requested). Injected by the app layer, which owns the notification
    /// centre; inert until then. The pane is carried so a click can focus its tab.
    @ObservationIgnored public var notificationPresenter:
        (@MainActor (WebNotificationRequest, UUID) -> Void)?

    /// Asks the OS for notification authorization and reports whether it is
    /// allowed. Injected by the app layer; returns false until then, which the
    /// polyfill reports to the page as a denied permission.
    @ObservationIgnored public var notificationPermissionRequester:
        (@MainActor () async -> Bool)?

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
        windowLayoutRepository: (any WindowLayoutRepository)? = nil,
        clock: any Clock,
        primaryWindow: WindowState? = nil
    ) {
        // Defaulted so a test does not have to build one. The app passes its
        // first window's state in, so the scene and the store agree on which
        // object holds the selection.
        self.primaryWindow = primaryWindow ?? WindowState()
        self.engine = engine
        self.repository = repository
        self.spaceRepository = spaceRepository
        self.historyRepository = historyRepository
        self.archiveRepository = archiveRepository
        self.folderRepository = folderRepository
        self.windowLayoutRepository = windowLayoutRepository
        self.clock = clock
        self.engine.delegate = self
        // Apply the persisted UA policy up front — the properties' `didSet` does
        // not fire for their initial values, so the engine would otherwise start
        // on the default with no per-domain rules.
        self.pushUserAgent()
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

        // A claim during restore must not pick up a latch set before it.
        pendingWindowKind = nil

        var restoredPrivateSpaceIDs: Set<UUID> = []
        do {
            let loaded = try await spaceRepository?.loadSpaces() ?? []
            // Self-healing: nothing writes a private Space today, but a profile
            // written by a build before this feature's guards existed would
            // otherwise resurrect one — the single thing private browsing must
            // never do. Cheaper than trusting that no such profile exists.
            restoredPrivateSpaceIDs = Set(loaded.filter(\.isPrivate).map(\.id))
            spaces = loaded.filter { !$0.isPrivate }
        } catch {
            Log.store.error("space restore failed: \(String(describing: error))")
            spaces = []
        }
        if spaces.isEmpty {
            spaces = [Space.makeDefault()]
            await persistSpaces()
        }
        primaryWindow.activeSpaceID = spaces[0].id

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
        // The one place a tab is dropped rather than re-homed (7.2 says never
        // delete user data in a migration, and this is not one): a tab belonging
        // to a private Space found on disk is the residue of a bug, and adopting
        // it would put a page from a private session into a real Space.
        if !restoredPrivateSpaceIDs.isEmpty {
            let before = tabs.count
            tabs.removeAll { restoredPrivateSpaceIDs.contains($0.spaceID) }
            let dropped = before - tabs.count
            Log.store.notice("dropped \(dropped) private tab(s)")
        }
        adoptOrphanedTabs()

        // Which Space and tab each window showed last session (v9). Empty on a
        // profile from before window layouts existed, or one saved with none —
        // then every window falls back to the default reconcile below.
        let layouts: [WindowLayout]
        do {
            layouts = try await windowLayoutRepository?.loadWindowLayouts() ?? []
        } catch {
            Log.store.error("window layout restore failed: \(String(describing: error))")
            layouts = []
        }
        applyRestoredLayouts(layouts)

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
            Log.store.notice("adopted \(adopted) orphaned tab(s)")
            scheduleSave()
        }
    }

    // MARK: - Commands

    /// - Parameter url: the destination, or `nil` to use the user's configured
    ///   new-tab behaviour (`resolvedNewTabURL`).
    /// - Parameter window: the window the tab opens in, defaulting to the primary
    ///   one. A new tab lands in *that* window's Space and becomes *its*
    ///   selection; other windows are untouched.
    /// - Parameter selecting: whether the new tab becomes the window's
    ///   selection. False for "Open Link in New Tab", where every browser leaves
    ///   you on the page you were reading — the point of that item is to queue
    ///   something up without losing your place.
    public func newTab(url: URL? = nil, in window: WindowState, selecting: Bool = true) {
        let target = url ?? resolvedNewTabURL
        insertTab(panes: [Pane(url: target)], in: window, selecting: selecting)
    }

    /// Opens a tab whose pane carries a *specific* id — the engine's
    /// `window.open()` popup is registered under that id, so the tab surfaces
    /// the popup's existing web view (keeping its live `window.open()` reference
    /// and `window.close()` semantics) instead of building a fresh one. See
    /// `paneRequestedPopup`.
    public func newTab(paneID: UUID, url: URL?, in window: WindowState, selecting: Bool = true) {
        let target = url ?? resolvedNewTabURL
        insertTab(panes: [Pane(id: paneID, url: target)], in: window, selecting: selecting)
    }

    /// The shared tail of both `newTab` forms: create an ephemeral single-pane
    /// tab in the window's active Space and make it that window's selection.
    private func insertTab(panes: [Pane], in window: WindowState, selecting: Bool) {
        guard let spaceID = activeSpace(in: window)?.id else { return }

        // Order is per-Space, so a new tab in one Space does not push another
        // Space's tabs down the list.
        let order = (visibleTabs(in: window).map(\.placement.order).max() ?? -1) + 1
        let tab = Tab(
            spaceID: spaceID,
            placement: .ephemeral(order: order),
            panes: panes,
            focusedPaneID: panes[0].id,
            lastAccessedAt: clock.now,
            createdAt: clock.now
        )
        tabs.append(tab)
        // A brand-new pane definitionally has nothing stored, so mark it
        // resolved rather than spending a disk read to discover that — and to
        // avoid withholding its surface for a frame.
        for pane in panes { stateResolution[pane.id] = .resolved }
        let previous = window.selectedTabID
        extensionHost?.extensionTabDidOpen(tab.id, inSpace: spaceID)
        if selecting {
            window.selectedTabID = tab.id
            extensionHost?.extensionTabDidActivate(tab.id, previous: previous, inSpace: spaceID)
        }
        scheduleSave()
    }

    /// Moves a tab to another Space. The pane's web view is torn down first: it
    /// belongs to the old Space's data store and must not carry those cookies
    /// across.
    public func moveTab(_ tabID: UUID, toSpace spaceID: UUID, in window: WindowState) {
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

        if window.selectedTabID == tabID {
            window.selectedTabID = visibleTabs(in: window).first?.id
            if window.selectedTabID == nil { newTab(in: window) }
        }
        // The tab left its old Space, so a window still showing that Space has
        // lost it even though nothing was closed.
        reconcileWindows(excluding: window)
        scheduleSave()
    }

    /// - Parameter window: the window doing the closing. It picks its own next
    ///   selection deliberately (the neighbour in the closed tab's slot); other
    ///   windows are only stopped from pointing at the tab that is gone.
    public func closeTab(_ tabID: UUID, in window: WindowState) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        // Favourites and Pinned tabs are not removed by a close (Cmd+W) — Arc
        // keeps them in the sidebar. Closing instead unloads the live view,
        // leaving the entry in place; a Pinned tab also returns to its home URL.
        guard tabs[index].placement.isEphemeral else {
            unloadTab(at: index, in: window)
            return
        }

        // Remember it for Cmd+Shift+T before the panes are torn down, so the
        // reopened tab carries its URLs, title, favicon, and pinned placement.
        //
        // Never for a private tab: `recentlyClosed` is store-wide, so Cmd+Shift+T
        // in a *normal* window minutes later would otherwise reopen a page from a
        // private session that has already ended. The least visible leak in this
        // feature, and the reason it is closed here rather than at reopen.
        if !isPrivate(spaceID: tabs[index].spaceID) {
            recentlyClosed.append(tabs[index])
            if recentlyClosed.count > Self.recentlyClosedLimit { recentlyClosed.removeFirst() }
        }

        for pane in tabs[index].panes {
            engine.evict(paneID: pane.id)
            runtimes[pane.id] = nil
        }
        // The tab and its panes are gone for good, so its sleep timer must not
        // fire later into nothing.
        cancelSleepTimer(tabID)
        forgetStateResolution(forPanes: tabs[index].panes.map(\.id))
        let closedSpaceID = tabs[index].spaceID
        let neighbours = visibleTabs(in: window)
        let closedPosition = neighbours.firstIndex { $0.id == tabID }
        tabs.remove(at: index)
        extensionHost?.extensionTabDidClose(tabID, inSpace: closedSpaceID)

        if window.selectedTabID == tabID {
            // Select the neighbour that is now in the closed tab's slot, within
            // this Space only.
            let remaining = visibleTabs(in: window)
            if let closedPosition, remaining.indices.contains(closedPosition) {
                window.selectedTabID = remaining[closedPosition].id
            } else {
                window.selectedTabID = remaining.last?.id
            }
        }
        if visibleTabs(in: window).isEmpty { newTab(in: window) }
        // The acting window just chose its neighbour deliberately; the others
        // only need to stop pointing at a tab that is gone.
        reconcileWindows(excluding: window)
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
    private func unloadTab(at index: Int, in window: WindowState) {
        let tabID = tabs[index].id

        // Another window still has it on screen, so there is nothing to unload —
        // tearing the view down here would blank that window's content.
        guard !isShown(tabID, byAnyWindowOtherThan: window) else {
            if window.selectedTabID == tabID {
                window.selectedTabID = visibleTabs(in: window).first { $0.id != tabID }?.id
                if window.selectedTabID == nil { newTab(in: window) }
            }
            return
        }

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
        if window.selectedTabID == tabID {
            if let next = visibleTabs(in: window).first(where: { $0.id != tabID }) {
                select(next.id, in: window)
            } else {
                window.selectedTabID = nil
                newTab(in: window)
            }
        }
        scheduleSave()
    }

    /// Pinning exempts a tab from the ephemeral sweep (4.3). Order is
    /// recomputed within the destination section so the two lists stay dense.
    public func setPinned(_ pinned: Bool, tabID: UUID) {
        // Pinning is a promise the tab will still be there; a private tab's
        // Space evaporates with its window. The UI hides these sections, so this
        // closes the command-bar and menu paths.
        guard !isPrivate(tabID: tabID) else { return }
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
        // Pinning is a promise the tab will still be there; a private tab's
        // Space evaporates with its window. The UI hides these sections, so this
        // closes the command-bar and menu paths.
        guard !isPrivate(tabID: tabID) else { return }
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
    public func returnToPinnedHome(_ tabID: UUID, in window: WindowState) {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let home = tab.placement.homeURL,
              tab.focusedPane.url != home
        else { return }
        select(tabID, in: window)
        navigate(to: home, in: window)
    }

    public func select(_ tabID: UUID, in window: WindowState) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        let outgoing = window.selectedTabID

        // A tab is on screen in at most one window — one web view, one superview.
        // Selecting one another window holds *moves* it here; that window is given
        // a tab of its own below, once this one has actually taken it.
        let donor = windowShowing(tabID, excluding: window)
        donor?.selectedTabID = nil

        // Capture before the switch, while the outgoing tab's view is still
        // live. This is the "persist on deactivation" rule in 3.2 — the only
        // point at which a tab the user merely switched away from gets its
        // state written.
        // Not when another window still shows it: capturing is fine, but the
        // pane is still live there and the blob would be rewritten on its next
        // switch anyway.
        if let outgoing, outgoing != tabID, !isShown(outgoing, byAnyWindowOtherThan: window) {
            captureInteractionState(forTab: outgoing)
        }

        window.selectedTabID = tabID
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

        // After the handover, so `reconcile` sees the tab as taken and picks the
        // donor a different one rather than immediately claiming it back.
        if let donor { reconcile(donor) }
    }

    public func navigate(to url: URL, in window: WindowState) {
        guard let tab = selectedTab(in: window) else { return }
        engine.load(url, in: tab.focusedPaneID)
        updatePane(tab.focusedPaneID) { $0.url = url }
        scheduleSave()
    }

    /// Prints the focused pane's page (M6). Searches the focused pane, like find
    /// (4.1): in a split, Cmd+P prints the pane you are reading.
    public func printSelectedPane(in window: WindowState) {
        selectedTab(in: window)
            .map { engine.printPane(paneID: $0.focusedPaneID) }
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

    /// Whether the tab's focused pane has a sleep timer armed (non-spec:
    /// user-requested).
    public func isSleepTimerArmed(_ tabID: UUID) -> Bool {
        sleepTimerDeadline(tabID) != nil
    }

    /// When the tab's focused pane's sleep timer fires, if one is armed
    /// (non-spec: user-requested).
    public func sleepTimerDeadline(_ tabID: UUID) -> Date? {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return nil }
        return runtime(for: tab.focusedPaneID).sleepTimerDeadline
    }

    /// Arms a sleep timer that pauses every pane's media when it fires, so a
    /// split's audio stops as one (non-spec: user-requested). Re-arming
    /// replaces the tab's existing timer. The engine keeps the deadline,
    /// surviving reload and eviction.
    public func setSleepTimer(minutes: Int, tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        cancelSleepTimer(tabID)
        let deadline = clock.now.addingTimeInterval(TimeInterval(minutes) * 60)
        for pane in tab.panes {
            engine.setSleepTimer(after: TimeInterval(minutes) * 60, paneID: pane.id)
            // Immediate UI feedback even when the pane has no live view to echo a
            // snapshot back; a live pane's snapshot confirms the same value.
            runtime(for: pane.id).sleepTimerDeadline = deadline
        }
    }

    /// Cancels the tab's sleep timer, if one is armed (non-spec:
    /// user-requested).
    public func cancelSleepTimer(_ tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        for pane in tab.panes {
            engine.cancelSleepTimer(paneID: pane.id)
            runtime(for: pane.id).sleepTimerDeadline = nil
        }
    }

    /// Ends screen sharing for the window's focused pane (non-spec:
    /// user-requested). Drives the "Stop" button on the sharing banner; the page
    /// reports `sharing:false` back, which clears the runtime flag.
    public func stopScreenSharing(in window: WindowState) {
        selectedTab(in: window)
            .map { engine.stopScreenSharing(paneID: $0.focusedPaneID) }
    }

    public func goBack(in window: WindowState) {
        selectedTab(in: window).map { engine.goBack(in: $0.focusedPaneID) }
    }

    public func goForward(in window: WindowState) {
        selectedTab(in: window).map { engine.goForward(in: $0.focusedPaneID) }
    }

    public func reload(in window: WindowState) {
        selectedTab(in: window).map { engine.reload(paneID: $0.focusedPaneID) }
    }

    public func stopLoading(in window: WindowState) {
        selectedTab(in: window)
            .map { engine.stopLoading(paneID: $0.focusedPaneID) }
    }

    /// Whether any window *other than* `window` is showing this tab. Guards the
    /// teardown paths: a tab on screen somewhere else is not idle.
    func isShown(_ tabID: UUID, byAnyWindowOtherThan window: WindowState) -> Bool {
        windows.contains { $0 !== window && $0.selectedTabID == tabID }
    }

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
            Log.store.error("no space for tab \(tab.id); refusing to render")
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
        // A private window's tabs are never written. `repository.save` replaces
        // the table wholesale, so filtering the input is the whole guard — and
        // every `scheduleSave()` caller inherits it here rather than each having
        // to remember.
        let snapshot = tabs.filter { !isPrivate(spaceID: $0.spaceID) }
        do {
            try await repository.save(snapshot)
        } catch {
            Log.store.error("tab save failed: \(String(describing: error))")
        }

        // Window layout (v9): which Space and tab each open window is showing, so
        // a relaunch restores them. Captured on the main actor, then written on
        // the persistence queue like everything else.
        let layouts = captureWindowLayouts()
        do {
            try await windowLayoutRepository?.saveWindowLayouts(layouts)
        } catch {
            Log.store.error("window layout save failed: \(String(describing: error))")
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
        let previous = runtime(for: paneID).loginForm
        let previousURL = runtime(for: paneID).currentURL
        runtime(for: paneID).apply(snapshot)

        // Which saved credentials this page could fill (V6). Computed *here*,
        // when the page reports, rather than in the view: a view-side async
        // lookup races the page load — the report and the URL arrive as separate
        // snapshots, and a task keyed on both can settle before either is final,
        // leaving the fill button hidden on a page that has a saved password.
        // Making it observable state the store owns removes the race entirely.
        if snapshot.loginForm != previous || snapshot.url != previousURL {
            refreshFillableCredentials(for: paneID)
        }

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

    public func paneRequestedPopup(url: URL?, popupPaneID: UUID, fromPane paneID: UUID?) {
        // A real popup web view is already live under `popupPaneID` (so the
        // opener's `window.open()` reference and `window.close()` work). Host it
        // as a tab in the window showing the page that asked, same placement
        // rule as a plain `window.open()` tab.
        newTab(
            paneID: popupPaneID,
            url: url,
            in: paneID.map { window(showingPane: $0) } ?? primaryWindow
        )
    }

    public func panePopupDidClose(_ paneID: UUID) {
        // `window.close()` only works on script-created windows, so the pane
        // naming this tab is a popup by construction. Close the tab hosting it;
        // if the user already did, there is nothing to close.
        guard let tabID = tabID(owning: paneID) else { return }
        closeTab(tabID, in: window(showingPane: paneID))
    }

    public func paneRequestedBackgroundTab(url: URL, fromPane paneID: UUID?) {
        // Background, and in the window showing the page the link came from. In a
        // private window that is the private window, so the link stays in the
        // private session — which is what the user asked for by right-clicking
        // there.
        newTab(
            url: url,
            in: paneID.map { window(showingPane: $0) } ?? primaryWindow,
            selecting: false
        )
    }

    public func paneRequestedPrivateWindow(url: URL) {
        // Opening a window is a scene concern, so the store marks the intent and
        // the app layer performs it — the same shape as `littleArcPresenter`.
        markNextWindowPrivate(opening: url)
        privateWindowPresenter?()
    }

    public func paneRequestedLittleArc(url: URL) {
        // The Little Arc panel is owned by the app layer (AppDelegate), so the
        // store forwards through an injected presenter rather than depending on
        // UI. No-op until it is wired — the same shape as `afterRestore`.
        littleArcPresenter?(url)
    }

    /// A plain left-click on a link inside a favourite/pinned tab (non-spec:
    /// user-requested): lift the navigation into the Peek panel instead of
    /// letting the click move the protected page. Returns true when the engine
    /// should cancel the navigation (the presenter accepted the preview).
    public func paneRequestedPeek(url: URL, fromPane paneID: UUID) -> Bool {
        guard let tabID = tabID(owning: paneID),
            let tab = tabs.first(where: { $0.id == tabID }),
            tab.placement.isPinned || tab.placement.isBookmarked
        else { return false }

        peekPresenter?(url, tab.spaceID)
        return true
    }

    public func paneDidSubmitLogin(
        origin: String, username: String, password: String, fromPane paneID: UUID
    ) {
        // Hop to a task: the decision needs the vault, which is async, and the
        // engine delegate call is synchronous.
        Task { await handleSubmittedLogin(
            origin: origin, username: username, password: password, paneID: paneID
        ) }
    }

    public func paneRequestedNotification(_ request: WebNotificationRequest, fromPane paneID: UUID) {
        // Owned by the app layer (Notification Center); inert until wired.
        notificationPresenter?(request, paneID)
    }

    public func paneRequestedMediaCapture(_ prompt: SitePermissionPrompt) async -> Bool {
        await requestSitePermission(prompt)
    }

    public func paneRequestedNotificationPermission(_ prompt: SitePermissionPrompt) async -> Bool {
        await requestSitePermission(prompt)
    }

    public func paneNotificationPermissionState(
        origin: String, paneID: UUID?
    ) async -> WebNotificationPermission {
        guard let spaceID = spaceID(forPane: paneID) else { return .notDetermined }
        let stored =
            (try? await sitePermissions?.decisions(forOrigin: origin, spaceID: spaceID)) ?? [:]
        switch stored[.notification] {
        case .granted: return .granted
        case .denied: return .denied
        case nil: return .notDetermined
        }
    }

    public func paneContentProcessDidTerminate(_ paneID: UUID) {
        // The engine already restarted the page. Nothing to do but note it —
        // the user should not see anything beyond a brief reload.
        Log.store.notice("recovered pane \(paneID) after process termination")
    }

    /// A delivered web notification was clicked: bring its page to the front and
    /// fire the page-side instance's `onclick` (non-spec: user-requested). The app
    /// layer activates the app; this selects the tab in a window showing it — the
    /// one already showing it, or the focused one, switching that window to the
    /// tab's Space first.
    public func handleNotificationClick(jsID: String, paneID: UUID) {
        guard let tab = tabs.first(where: { $0.panes.contains { $0.id == paneID } }) else { return }
        let window = windowShowing(tab.id) ?? focusedWindow
        selectSpace(tab.spaceID, in: window)  // no-op if already there
        select(tab.id, in: window)
        engine.dispatchNotificationClick(jsID: jsID, toPane: paneID)
    }
}
