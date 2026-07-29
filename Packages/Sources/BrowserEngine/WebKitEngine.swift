import AppKit
import BrowserCore
import Foundation
import WebKit

public struct EngineConfiguration: Sendable {
    /// Matches the inset card's radius in the UI layer.
    public var cornerRadius: CGFloat
    public var liveViewCapacity: Int
    public var faviconCacheDirectory: URL
    public var applicationName: String

    public init(
        cornerRadius: CGFloat = 10,
        liveViewCapacity: Int = 12,
        faviconCacheDirectory: URL,
        applicationName: String = "Browser"
    ) {
        self.cornerRadius = cornerRadius
        self.liveViewCapacity = liveViewCapacity
        self.faviconCacheDirectory = faviconCacheDirectory
        self.applicationName = applicationName
    }
}

/// The only type in the app that touches `WKWebView`.
@MainActor
public final class WebKitEngine: WebEngine {
    public weak var delegate: (any WebEngineDelegate)?

    /// Set once at launch by `AppEnvironment`. Consulted per web view; not
    /// retained by any configuration, so flipping it affects only views built
    /// afterwards (M7).
    public weak var extensionControllerProvider: (any ExtensionControllerProviding)?

    // Internal, not private: the `PaneWebViewProviding` conformance (7.3b) lives
    // in its own file and reads a pane's live view from the pool.
    let pool: WebViewPool
    private let dataStores = DataStoreRegistry()
    private let favicons: FaviconLoader
    private let configuration: EngineConfiguration

    // BROWSER_SPEC 6.2 asks for a shared WKProcessPool. Apple deprecated the
    // whole type in macOS 12 — "Creating and using multiple instances of
    // WKProcessPool no longer has any effect" — so process sharing is now
    // governed by the data store, not by us. Setting it would only buy a
    // deprecation warning, and we build warnings-as-errors. See ADR 004.

    private var coordinator: NavigationCoordinator?

    /// Owns `WKDownload` and its delegate. Public so the UI can list and cancel
    /// downloads without WebKit appearing in any signature it can see.
    public let downloads: DownloadCoordinator

    /// The compiled native content-blocking lists (§4.8). Empty until the first
    /// compile finishes. Attached to every web view's content controller. The
    /// full EasyList + EasyPrivacy exceeds one list's practical size, so it is
    /// split across several immutable compiled lists, all attached together.
    private var contentRuleLists: [WKContentRuleList] = []

    /// The user's chosen User-Agent override (non-spec: user-requested), or `nil`
    /// for the browser's own completed Safari UA. Applied to every web view built
    /// afterwards and pushed onto any already live. See `UserAgentPreference`.
    private var customUserAgent: String?

    /// The OS notification decision, mirrored into the web-facing
    /// `Notification.permission` so a returning page reads its real state instead
    /// of `default` and stops re-prompting. Seeds views built afterwards; live
    /// views are updated directly. Set from the app layer (`setNotificationPermission`).
    private var notificationPermission: WebNotificationPermission = .notDetermined

    /// Retained so an evicted or crashed pane can be revived without the model
    /// layer having to hand its state back.
    private var interactionStates: [UUID: Data] = [:]
    /// Last known URL per pane, for reload-after-crash.
    private var lastKnownURL: [UUID: URL] = [:]

    /// The URL of the most recently right-clicked link per pane, fed by
    /// `ContextLinkMonitor` and read when "Open in Little Chord" is chosen.
    private var contextLinkURL: [UUID: URL] = [:]

    /// Panes the user has muted (non-spec: user-requested). Kept here, not on the
    /// view, so a muted pane stays muted across eviction and reload.
    private var mutedPanes: Set<UUID> = []

    public init(
        configuration: EngineConfiguration,
        downloads: DownloadCoordinator = DownloadCoordinator()
    ) {
        self.configuration = configuration
        self.downloads = downloads
        self.pool = WebViewPool(capacity: configuration.liveViewCapacity)
        self.favicons = FaviconLoader(cacheDirectory: configuration.faviconCacheDirectory)

        self.coordinator = NavigationCoordinator(engine: self)
        self.pool.willEvict = { [weak self] paneID, state in
            guard let self, let state else { return }
            self.interactionStates[paneID] = state
        }
    }

    // MARK: - Surfaces

    public func surface(for pane: Pane, in space: Space) -> AnyWebSurface {
        let live = liveView(for: pane, in: space)
        return AnyWebSurface(id: pane.id, container: live.container)
    }

    public func removeData(for space: Space) async throws {
        guard !space.isPrivate else { return }  // nothing on disk to reclaim
        dataStores.forget(spaceID: space.id)
        try await dataStores.removePersistentStore(dataStoreID: space.dataStoreID)
    }

    public func clearWebsiteData(_ types: BrowsingDataType, forSpaces spaces: [Space]) async {
        let wkTypes = Self.websiteDataTypes(for: types)
        guard !wkTypes.isEmpty else { return }
        // `modifiedSince: .distantPast` == everything. Each Space's store is
        // cleared independently so isolation is preserved: one Space losing its
        // cookies never touches another's.
        for space in spaces {
            let store = dataStores.store(for: space)
            await store.removeData(ofTypes: wkTypes, modifiedSince: .distantPast)
        }
    }

    /// Maps the WebKit-free `BrowsingDataType` onto the concrete
    /// `WKWebsiteDataType*` constants (verified against the SDK headers).
    nonisolated static func websiteDataTypes(for types: BrowsingDataType) -> Set<String> {
        var result: Set<String> = []
        if types.contains(.cache) {
            result.formUnion([
                WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeOfflineWebApplicationCache,
            ])
        }
        if types.contains(.cookies) {
            result.insert(WKWebsiteDataTypeCookies)
        }
        if types.contains(.siteStorage) {
            result.formUnion([
                WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage,
                WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeServiceWorkerRegistrations,
                WKWebsiteDataTypeWebSQLDatabases, WKWebsiteDataTypeFileSystem,
            ])
        }
        return result
    }

    private func liveView(for pane: Pane, in space: Space) -> LiveWebView {
        if let existing = pool.view(for: pane.id) { return existing }

        let webView = makeWebView(for: space)
        let live = LiveWebView(
            paneID: pane.id, webView: webView, cornerRadius: configuration.cornerRadius
        )
        live.startObserving { [weak self] paneID, snapshot in
            self?.handleSnapshot(snapshot, for: paneID)
        }
        // A revived pane that was muted stays muted — the JS is (re)applied on
        // didFinish; this seeds the snapshot so the UI is right immediately.
        live.isMuted = mutedPanes.contains(pane.id)
        pool.insert(live)

        // Prefer restoring over reloading: interactionState brings back scroll
        // position and back/forward history, and costs no network (6.2).
        let state = pane.interactionState ?? interactionStates[pane.id]
        if let state {
            live.restore(interactionState: state)
        } else {
            webView.load(URLRequest(url: pane.url))
        }
        lastKnownURL[pane.id] = pane.url

        Log.engine.debug(
            "created web view for pane \(pane.id, privacy: .public), \(self.pool.count) live"
        )
        return live
    }

    private func makeWebView(for space: Space) -> WKWebView {
        // Copying a template is cheaper than rebuilding a configuration, and
        // rebuilding recompiles content rule lists (6.2). The data store is the
        // one thing that varies per Space.
        let config = Self.configurationTemplate.copy() as! WKWebViewConfiguration
        config.websiteDataStore = dataStores.store(for: space)

        // Attach this Space's extension controller, if the host has one loaded
        // (M7). Left unset when the Space has no extensions, so a configuration
        // for an extension-free Space is exactly what it was before M7. The
        // controller stays behind the opaque handle — no WebKit type reaches
        // here from above the engine. See ADR 011.
        if let handle = extensionControllerProvider?.extensionControllerHandle(for: space) {
            config.webExtensionController = handle.controller
        }

        // Each view gets its own content controller. `WKWebViewConfiguration.copy()`
        // does *not* deep-copy this object, so sharing the template's controller
        // means adding the same handler name twice — which throws
        // NSInvalidArgumentException and takes the app down on the second tab.
        let controller = WKUserContentController()
        controller.addUserScript(MediaActivityMonitor.makeUserScript())
        controller.addUserScript(ContextLinkMonitor.makeUserScript())
        controller.addUserScript(AudioMuteController.makeUserScript())
        controller.addUserScript(PeekLinkMonitor.makeUserScript())
        controller.addUserScript(
            NotificationBridge.makeUserScript(notificationPermission: notificationPermission)
        )
        controller.addUserScript(ScreenShareMonitor.makeUserScript())
        controller.addUserScript(YouTubeAdBlocker.makeUserScript())
        if let coordinator {
            controller.add(coordinator, name: MediaActivityMonitor.messageName)
            controller.add(coordinator, name: ContextLinkMonitor.messageName)
            controller.add(coordinator, name: PeekLinkMonitor.messageName)
            controller.add(coordinator, name: NotificationBridge.showMessageName)
            controller.add(coordinator, name: ScreenShareMonitor.messageName)
            // requestPermission() needs the native decision back, so it is a
            // with-reply handler installed in the page world. The coordinator
            // conforms to both handler protocols, so the cast selects the
            // with-reply overload (Swift maps both to `addScriptMessageHandler`).
            controller.addScriptMessageHandler(
                coordinator as any WKScriptMessageHandlerWithReply,
                contentWorld: .page,
                name: NotificationBridge.permissionMessageName
            )
        }
        // Native content blocking (§4.8, C2). The compiled list is shared and
        // immutable; adding it to each view's controller is what actually
        // enforces the rules. Nil when the feature is off or the first-launch
        // compile is still in flight — `applyContentRuleLists` retrofits those.
        for list in contentRuleLists {
            controller.add(list)
        }
        config.userContentController = controller

        let webView = ChordWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.configuration.preferences.setValue(true, forKey: "fullScreenEnabled")
        webView.allowsMagnification = true
        webView.customUserAgent = customUserAgent
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator

        // "Open in Little Chord" on a link's context menu. The URL is resolved at
        // click time from the pane's last reported link, and routed out through
        // the engine's delegate to the app's Little Arc panel.
        webView.contextLinkURL = { [weak self, weak webView] in
            guard let self, let webView, let paneID = self.paneID(for: webView) else { return nil }
            return self.contextLinkURL[paneID]
        }
        webView.onOpenInLittleArc = { [weak self] url in
            self?.delegate?.paneRequestedLittleArc(url: url)
        }
        return webView
    }

    /// Installs the compiled content-blocking lists (§4.8), applying them both
    /// to views built afterwards and to any already live — first-launch
    /// compilation finishes after the first views exist, so those must be
    /// retrofitted or they would browse unblocked until reloaded. An empty array
    /// clears them. Immutable and shared, so the same objects attach to every
    /// view.
    public func applyContentRuleLists(_ lists: [WKContentRuleList]) {
        contentRuleLists = lists
        for live in pool.liveViews {
            let controller = live.webView.configuration.userContentController
            controller.removeAllContentRuleLists()
            for list in lists {
                controller.add(list)
            }
        }
    }

    /// Sets the User-Agent every web view presents (non-spec: user-requested),
    /// or `nil` to restore the browser's own completed Safari UA. Stored so views
    /// built later inherit it, and pushed onto every live view now. `nil` on a
    /// live view restores the engine's default UA (the `applicationNameForUserAgent`
    /// completion still applies, since that lives on the configuration).
    public func setCustomUserAgent(_ userAgent: String?) {
        customUserAgent = userAgent
        for live in pool.liveViews {
            live.webView.customUserAgent = userAgent
        }
    }

    public func setNotificationPermission(_ permission: WebNotificationPermission) {
        guard permission != notificationPermission else { return }
        notificationPermission = permission
        // Views built afterwards inherit the new seed via `makeUserScript`; push
        // it into pages already open so they update without a reload.
        let script = NotificationBridge.updatePermissionScript(permission)
        for live in pool.liveViews {
            live.webView.evaluateJavaScript(script) { _, _ in }
        }
    }

    /// Completes the User-Agent so it looks like the browser it actually is.
    ///
    /// WKWebView's default UA ends at `(KHTML, like Gecko)` — no `Version/` and
    /// no `Safari/` token, because both come from
    /// `applicationNameForUserAgent`, which is unset by default. Sites sniff
    /// for those: Google serves a stripped-down page to a UA with no browser
    /// token at all, which is what made its home page look wrong here.
    ///
    /// This is **not** the Chrome spoofing §9.6 warns against. We are WebKit,
    /// running the same engine at the same version Safari does; saying so is
    /// accurate. For the handful of sites that demand Chrome specifically, the
    /// user can override the UA in Settings (`UserAgentPreference`, applied via
    /// `setCustomUserAgent`); a bundled per-domain map remains a future option.
    ///
    /// The version is hard-coded and will go stale. That is the accepted cost:
    /// WebKit exposes no API for the Safari version, reading Safari's own
    /// Info.plist is blocked by the sandbox, and a stale-but-plausible version
    /// degrades far more gracefully than no token at all.
    static let safariUserAgentSuffix = "Version/26.5 Safari/605.1.15"

    private static let configurationTemplate: WKWebViewConfiguration = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.applicationNameForUserAgent = safariUserAgentSuffix
        // The user script and message handler are installed per view, not here:
        // copy() shares this controller between every copy.
        return config
    }()

    func setPlayingAudio(_ playing: Bool, for paneID: UUID) {
        guard let live = pool.view(for: paneID), live.isPlayingAudio != playing else { return }
        live.isPlayingAudio = playing
        handleSnapshot(live.snapshot, for: paneID)
    }

    /// Records whether the pane is screen-sharing, as reported from inside the
    /// page (see `ScreenShareMonitor`), and republishes the snapshot so the
    /// "sharing" banner tracks it.
    func setScreenSharing(_ sharing: Bool, for paneID: UUID) {
        guard let live = pool.view(for: paneID), live.isScreenSharing != sharing else { return }
        live.isScreenSharing = sharing
        handleSnapshot(live.snapshot, for: paneID)
    }

    /// Stops every display-capture stream the pane holds, ending screen sharing.
    /// A no-op without a live view — a page that is gone cannot be sharing. The
    /// page reports the resulting `sharing:false` itself, which clears the state.
    public func stopScreenSharing(paneID: UUID) {
        guard let live = pool.peek(paneID) else { return }
        live.webView.evaluateJavaScript(ScreenShareMonitor.stopScript) { _, _ in }
    }

    /// Records (or clears) the link the pane's page reported under the last
    /// right-click. `nil` when the click was not over a link.
    func setContextLinkURL(_ url: URL?, for paneID: UUID) {
        contextLinkURL[paneID] = url
    }

    // MARK: - Mute

    public func setMuted(_ muted: Bool, paneID: UUID) {
        if muted { mutedPanes.insert(paneID) } else { mutedPanes.remove(paneID) }
        guard let live = pool.peek(paneID) else { return }
        live.isMuted = muted
        applyMuteJS(muted, to: live.webView)
        handleSnapshot(live.snapshot, for: paneID)
    }

    /// Re-asserts a pane's mute state into a freshly-built JS context — called
    /// after each navigation, since a reload wipes the injected function's state.
    func reapplyMute(paneID: UUID) {
        guard mutedPanes.contains(paneID), let live = pool.peek(paneID) else { return }
        live.isMuted = true
        applyMuteJS(true, to: live.webView)
    }

    private func applyMuteJS(_ muted: Bool, to webView: WKWebView) {
        webView.evaluateJavaScript(
            "\(AudioMuteController.setMutedFunction)(\(muted));", completionHandler: nil
        )
    }

    // MARK: - Navigation

    public func load(_ url: URL, in paneID: UUID) {
        guard let live = pool.view(for: paneID) else { return }
        lastKnownURL[paneID] = url
        live.webView.load(URLRequest(url: url))
    }

    public func goBack(in paneID: UUID) { pool.view(for: paneID)?.webView.goBack() }
    public func goForward(in paneID: UUID) { pool.view(for: paneID)?.webView.goForward() }
    public func reload(paneID: UUID) { pool.view(for: paneID)?.webView.reload() }
    public func stopLoading(paneID: UUID) { pool.view(for: paneID)?.webView.stopLoading() }

    public func snapshot(for paneID: UUID) -> PaneSnapshot? {
        pool.view(for: paneID)?.snapshot
    }

    // MARK: - Print

    public func printPane(paneID: UUID) {
        // Only a pane with a live view can be printed — its `printOperation`
        // renders the view's current content, so restore-lazy panes have nothing
        // to hand the printer.
        guard let webView = pool.view(for: paneID)?.webView else { return }

        // Without a window there is no print — and it must go through
        // `runModal(for:…)`, not `runOperation()`. WebKit builds its printing
        // view lazily against a window context, and the synchronous
        // `runOperation()` runs before that context exists, so AppKit puts up
        // "This application does not support printing." The window-anchored sheet
        // form gives WebKit the context and prints correctly. Verified by hand —
        // `.run()` failed on both HTML and PDF pages, the sheet works.
        guard let window = webView.window else { return }

        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: - Find in page

    public func find(_ text: String, in paneID: UUID, backwards: Bool) async -> Bool {
        guard !text.isEmpty, let webView = pool.view(for: paneID)?.webView else { return false }

        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        // Wrapping is the default and the right one here: a find bar that stops
        // dead at the end of the document reads as "no more matches" when there
        // are several above the fold.
        configuration.wraps = true
        // Case-insensitive, matching every other find bar on the platform.
        configuration.caseSensitive = false

        // The Swift refinement of `findString(_:withConfiguration:...)` is
        // throwing. A thrown find is not a miss to report loudly — it means
        // the page went away mid-search — so it reads as "no match".
        do {
            return try await webView.find(text, configuration: configuration).matchFound
        } catch {
            Log.engine.debug("find failed: \(error.localizedDescription)")
            return false
        }
    }

    public func clearFind(in paneID: UUID) {
        // WebKit has no "stop finding" call in the modern API — the old
        // `hideFindUI`/`stopFinding` pair belongs to the legacy WebView. What
        // clears the highlight is collapsing the selection the find left
        // behind, which is what the deselect-all command does.
        guard let webView = pool.view(for: paneID)?.webView else { return }
        // Failure is not worth surfacing: the page may have navigated away or
        // be mid-load, and the only consequence is a highlight that outlives
        // the find bar by one navigation.
        webView.evaluateJavaScript("window.getSelection().removeAllRanges()") { _, error in
            if let error { Log.engine.debug("clearFind: \(error.localizedDescription)") }
        }
    }

    // MARK: - Lifecycle

    @discardableResult
    public func evict(paneID: UUID) -> Data? {
        let state = pool.evict(paneID)
        if let state { interactionStates[paneID] = state }
        return state
    }

    public func evictAll() { pool.evictAll() }

    /// Prefers the live view's current state over the last captured one, so a
    /// tab the user has scrolled since it was revived persists where they
    /// actually left it.
    public func interactionState(for paneID: UUID) -> Data? {
        if let live = pool.peek(paneID), let state = live.interactionState {
            interactionStates[paneID] = state
            return state
        }
        return interactionStates[paneID]
    }

    public func hasLiveView(paneID: UUID) -> Bool {
        pool.contains(paneID)
    }

    public func dispatchNotificationClick(jsID: String, toPane paneID: UUID) {
        guard let live = pool.view(for: paneID) else { return }
        live.webView.evaluateJavaScript(NotificationBridge.clickScript(jsID: jsID)) { _, _ in }
    }

    public func seedInteractionState(_ data: Data, for paneID: UUID) {
        guard !pool.contains(paneID) else { return }
        interactionStates[paneID] = data
    }

    public func liveViewCount() -> Int { pool.count }

    // MARK: - Coordinator callbacks

    func paneID(for webView: WKWebView) -> UUID? {
        // The pool is capped at 12, so a linear scan here is cheaper than
        // maintaining a second index.
        pool.paneID(matching: webView)
    }

    func publishSnapshot(for paneID: UUID) {
        guard let live = pool.view(for: paneID) else { return }
        live.refreshSnapshot()
        handleSnapshot(live.snapshot, for: paneID)
    }

    private func handleSnapshot(_ snapshot: PaneSnapshot, for paneID: UUID) {
        if let url = snapshot.url { lastKnownURL[paneID] = url }
        delegate?.paneDidUpdate(paneID, snapshot: snapshot)
    }

    /// Rebuilds the page in place after a content process death, using
    /// interactionState when WebKit left us one.
    func recoverFromTermination(paneID: UUID) {
        guard let live = pool.view(for: paneID) else { return }

        if let state = live.interactionState ?? interactionStates[paneID] {
            live.restore(interactionState: state)
        } else if let url = lastKnownURL[paneID] {
            live.webView.load(URLRequest(url: url))
        }

        delegate?.paneContentProcessDidTerminate(paneID)
    }

    func fetchFavicon(for paneID: UUID) {
        guard let live = pool.view(for: paneID), let pageURL = live.webView.url else { return }

        let script = """
        (function () {
          var link = document.querySelector("link[rel~='icon']");
          return link ? link.href : null;
        })()
        """

        live.webView.evaluateJavaScript(script) { [weak self] result, _ in
            MainActor.assumeIsolated {
                let declared = (result as? String).flatMap(URL.init(string:))
                Task { [weak self] in
                    guard let self else { return }
                    let data = await self.favicons.favicon(
                        for: pageURL, declaredHref: declared
                    )
                    self.delegate?.paneDidLoadFavicon(paneID, data: data)
                }
            }
        }
    }

    /// Pauses network-bound background work while the window is occluded (6.3).
    public func setOccluded(_ occluded: Bool) {
        Task { await favicons.setPaused(occluded) }
    }

    // MARK: - Downloads

    func adoptDownload(_ download: WKDownload, suggestedURL: URL?) {
        downloads.adopt(download, suggestedURL: suggestedURL)
    }
}
