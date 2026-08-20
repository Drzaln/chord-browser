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
    /// Watches for the "undo page" swipe on panes that have nothing to undo
    /// (non-spec: user-requested experiment). See `BackSwipeMonitor`.
    private let backSwipe: BackSwipeMonitor
    /// Mirrors the persisted preference; the store pushes it on launch and on
    /// change. Starts on so the monitor runs from the first frame; the store's
    /// initial push corrects it to whatever the user chose.
    private var swipeToCloseEnabled = true

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

    /// The User-Agent policy (§9.6): the global preference, plus the per-domain
    /// overrides that beat it. Which one applies is resolved per navigation from
    /// the URL — see `applyUserAgent(to:for:)`.
    private var globalUserAgent: UserAgentPreference = .default
    private var userAgentOverrides: [UserAgentOverride] = []

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

    /// When each pane's sleep timer fires (non-spec: user-requested). Owned
    /// here, not in the page, so it survives reload and view eviction — a page's
    /// `setTimeout` would be throttled in a background tab and wiped on reload,
    /// which are exactly the moments a sleep timer must not die. See
    /// `SleepTimerController`.
    private var sleepTimers: [UUID: Date] = [:]
    /// The pending native fire per pane, so a re-armed or cancelled timer drops
    /// the stale one.
    private var sleepTimerFires: [UUID: DispatchWorkItem] = [:]

    public init(
        configuration: EngineConfiguration,
        downloads: DownloadCoordinator = DownloadCoordinator()
    ) {
        self.configuration = configuration
        self.downloads = downloads
        self.pool = WebViewPool(capacity: configuration.liveViewCapacity)
        self.favicons = FaviconLoader(cacheDirectory: configuration.faviconCacheDirectory)
        self.backSwipe = BackSwipeMonitor()

        self.coordinator = NavigationCoordinator(engine: self)
        self.pool.willEvict = { [weak self] paneID, state in
            guard let self, let state else { return }
            self.interactionStates[paneID] = state
        }

        // A rightward swipe that WebKit's native back/forward gesture had
        // nothing to navigate to: hand the pane up so the store can decide
        // between closing its tab and dismissing a Little Chord panel.
        self.backSwipe.onSwipeRightNoHistory = { [weak self] webView in
            guard let self, let paneID = self.paneID(for: webView) else { return }
            self.delegate?.paneRequestedSwipeClose(paneID)
        }
        self.backSwipe.start()
    }

    // MARK: - Surfaces

    public func surface(for pane: Pane, in space: Space) -> AnyWebSurface {
        let live = liveView(for: pane, in: space)
        return AnyWebSurface(id: pane.id, container: live.container)
    }

    public func removeData(for space: Space) async throws {
        // The registry is dropped first, and for a private Space that is the
        // *whole* job: a `.nonPersistent()` store has nothing on disk, but it is
        // still cached here, so leaving it would keep a closed private session's
        // cookies in memory for the life of the process. The early return used
        // to sit above this line.
        dataStores.forget(spaceID: space.id)
        guard !space.isPrivate else { return }  // nothing on disk to reclaim
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
        // The UA is resolved against the page this pane is on, not globally
        // (§9.6): a per-domain rule has to be in place before the first request.
        applyUserAgent(to: webView, for: pane.url)
        let live = LiveWebView(
            paneID: pane.id, webView: webView, cornerRadius: configuration.cornerRadius
        )
        live.startObserving { [weak self] paneID, snapshot in
            self?.handleSnapshot(snapshot, for: paneID)
        }
        // A revived pane that was muted stays muted — the JS is (re)applied on
        // didFinish; this seeds the snapshot so the UI is right immediately.
        live.isMuted = mutedPanes.contains(pane.id)
        // A sleep timer that fired while this pane had no live view pauses as
        // soon as it revives — see `reapplySleepTimer`.
        reapplySleepTimer(paneID: pane.id)
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
            "created web view for pane \(pane.id), \(self.pool.count) live"
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

        config.userContentController = makeContentController()
        let webView = ChordWebView(frame: .zero, configuration: config)
        configure(webView)
        return webView
    }

    /// The per-view message-handler and user-script wiring, shared by every
    /// web view the engine builds — normal panes and `window.open()` popups
    /// alike. Each view gets its own controller; `WKWebViewConfiguration.copy()`
    /// does *not* deep-copy this object, so sharing the template's controller
    /// means adding the same handler name twice — which throws
    /// NSInvalidArgumentException and takes the app down on the second tab.
    private func makeContentController() -> WKUserContentController {
        let controller = WKUserContentController()
        controller.addUserScript(MediaActivityMonitor.makeUserScript())
        controller.addUserScript(ContextLinkMonitor.makeUserScript())
        controller.addUserScript(AudioMuteController.makeUserScript())
        controller.addUserScript(SleepTimerController.makeUserScript())
        controller.addUserScript(NotificationBridge.makeUserScript())
        controller.addUserScript(ScreenShareMonitor.makeUserScript())
        controller.addUserScript(YouTubeAdBlocker.makeUserScript())
        controller.addUserScript(PasswordFormMonitor.makeUserScript())
        if let coordinator {
            controller.add(coordinator, name: MediaActivityMonitor.messageName)
            controller.add(coordinator, name: ContextLinkMonitor.messageName)
            controller.add(coordinator, name: NotificationBridge.showMessageName)
            controller.add(coordinator, name: ScreenShareMonitor.messageName)
            controller.add(coordinator, name: PasswordFormMonitor.messageName)
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
        return controller
    }

    /// The shared post-configuration a web view needs before it is usable —
    /// gestures, delegates, and the context-menu callbacks. Called from both
    /// `makeWebView` and `makePopupWebView`.
    private func configure(_ webView: ChordWebView) {
        webView.allowsBackForwardNavigationGestures = true
        webView.configuration.preferences.setValue(true, forKey: "fullScreenEnabled")
        webView.allowsMagnification = true
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator

        // "Open in Little Chord" on a link's context menu. The URL is resolved at
        // click time from the pane's last reported link, and routed out through
        // the engine's delegate to the app's Little Chord panel.
        webView.contextLinkURL = { [weak self, weak webView] in
            guard let self, let webView, let paneID = self.paneID(for: webView) else { return nil }
            return self.contextLinkURL[paneID]
        }
        webView.onOpenInLittleChord = { [weak self] url in
            self?.delegate?.paneRequestedLittleChord(url: url)
        }
        // The pane is named so the tab lands in the window showing this page —
        // the same reason `window.open()` carries it.
        webView.onOpenInNewTab = { [weak self, weak webView] url in
            guard let self, let webView else { return }
            self.delegate?.paneRequestedBackgroundTab(
                url: url, fromPane: self.paneID(for: webView)
            )
        }
        webView.onOpenInPrivateWindow = { [weak self] url in
            self?.delegate?.paneRequestedPrivateWindow(url: url)
        }
    }

    /// Builds and adopts the real popup web view a `window.open()` / popup
    /// request gets (`createWebViewWith`), and tells the delegate to host it as
    /// a tab.
    ///
    /// Unlike a plain store-opened tab, this view is created by WebKit from the
    /// opener's configuration, so the page's `window.open()` call returns a
    /// *live* window reference — which is what OAuth login (Shopee's Google
    /// button, etc.) polls (`win.closed`) or reads the auth result from — and
    /// `window.close()` actually closes the popup instead of being silently
    /// ignored, so the tab does not linger. Note WKWebView leaves
    /// `window.opener` null even for these popups (a known WebKit limitation);
    /// the return value of `window.open()` is the mechanism OAuth flows rely on
    /// here. The configuration is copied but its data store and extension
    /// controller carry over; only the content controller is rebuilt, so the
    /// popup gets our message handlers, user scripts, and content-blocking
    /// lists exactly once, like any other pane. WebKit performs the navigation
    /// into the returned view itself, so no load is issued here.
    ///
    /// The view is registered in the pool under `popupPaneID` *before* the
    /// store is asked to open the tab, so when the tab is selected the
    /// `surface(for:in:)` path finds it and shows it — it is never replaced by
    /// a fresh normal view. Returns the view WebKit must receive.
    @discardableResult
    func makeAndAdoptPopup(
        openerConfiguration: WKWebViewConfiguration, url: URL?, fromPane paneID: UUID?
    ) -> WKWebView {
        let config = openerConfiguration.copy() as! WKWebViewConfiguration
        config.userContentController = makeContentController()
        let webView = ChordWebView(frame: .zero, configuration: config)
        configure(webView)
        // Resolve the UA at creation, like `liveView` does, so the popup's
        // *first* navigation is not cancelled-and-re-issued by the policy
        // (6.2/§9.6). Re-issuing that first load is what breaks the
        // `window.opener` relationship WebKit set up for the popup.
        applyUserAgent(to: webView, for: url)

        let popupPaneID = UUID()
        let live = LiveWebView(
            paneID: popupPaneID, webView: webView, cornerRadius: configuration.cornerRadius
        )
        live.startObserving { [weak self] paneID, snapshot in
            self?.handleSnapshot(snapshot, for: paneID)
        }
        pool.insert(live)
        lastKnownURL[popupPaneID] = url
        Log.engine.debug("created popup web view for pane \(popupPaneID), \(self.pool.count) live")

        delegate?.paneRequestedPopup(url: url, popupPaneID: popupPaneID, fromPane: paneID)
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
    public func setUserAgent(_ global: UserAgentPreference, overrides: [UserAgentOverride]) {
        globalUserAgent = global
        userAgentOverrides = overrides
        // Live views are re-resolved against the page each is *currently* on, so
        // changing the rule for one site does not restamp every other tab with
        // the wrong UA. It takes effect on their next load, as before.
        for live in pool.liveViews {
            applyUserAgent(to: live.webView, for: live.webView.url)
        }
    }

    /// Starts or stops the swipe-to-close monitor. The monitor's start/stop is
    /// idempotent, so toggling only ever does the work the flag actually asks
    /// for.
    public func setSwipeToCloseEnabled(_ enabled: Bool) {
        guard enabled != swipeToCloseEnabled else { return }
        swipeToCloseEnabled = enabled
        if enabled {
            backSwipe.start()
        } else {
            backSwipe.stop()
        }
    }

    /// Points one web view at the UA its URL should get. Returns whether it
    /// changed, which the navigation policy uses to decide whether a request
    /// already in flight has to be re-issued.
    @discardableResult
    func applyUserAgent(to webView: WKWebView, for url: URL?) -> Bool {
        let resolved = UserAgentRules.resolve(
            url: url, overrides: userAgentOverrides, global: globalUserAgent
        )
        // **`customUserAgent` reads back as `""`, not `nil`, when it is unset.**
        // Comparing against `nil` therefore always reports a change, and the
        // navigation policy above — which cancels and re-issues on a change —
        // cancelled every load forever. It presents as a page that simply never
        // arrives, with no error: the e2e UA test caught it, and a print in the
        // policy is what showed the same URL being decided seven times.
        let current = (webView.customUserAgent?.isEmpty ?? true) ? nil : webView.customUserAgent
        guard current != resolved else { return false }
        webView.customUserAgent = resolved
        return true
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
    /// The Safari-version token appended to every UA. One source of truth in
    /// `BrowserCore` (`UserAgentPreference.safariVersionToken`), so the live UA
    /// and the Settings prefill can never advertise different versions.
    static let safariUserAgentSuffix = UserAgentPreference.safariVersionToken

    private static let configurationTemplate: WKWebViewConfiguration = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.applicationNameForUserAgent = safariUserAgentSuffix
        config.preferences.setValue(true, forKey: "managedMediaSourceEnabled")
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

    /// Records what the page reports about its login fields (V3 of the password
    /// vault). Called from the coordinator after `LoginFormClassifier` has judged
    /// the descriptors, so no DOM detail reaches the pool.
    func setLoginForm(_ analysis: LoginFormAnalysis, for paneID: UUID) {
        guard let live = pool.view(for: paneID), live.loginForm != analysis else { return }
        live.loginForm = analysis
        handleSnapshot(live.snapshot, for: paneID)
    }

    /// Fills a credential into the fields the page reported (V4). See the
    /// protocol for why the origin is re-checked here rather than trusted.
    /// Which origins may hold a credential. `.strict` in the app; the e2e suite
    /// relaxes it to reach its loopback HTTP server. See `CredentialOrigin.Policy`.
    public var loginOriginPolicy: CredentialOrigin.Policy = .strict

    public func fillLogin(
        paneID: UUID,
        expectedOrigin: String,
        usernameFieldID: String?,
        username: String,
        passwordFieldID: String?,
        password: String
    ) async -> LoginFillOutcome {
        guard let live = pool.peek(paneID) else { return .noPane }

        // The check that matters, and it is deliberately *here* — the last point
        // before the secret enters the page, against the URL the view is
        // actually showing right now.
        guard let current = live.webView.url,
            CredentialOrigin.matches(
                stored: expectedOrigin, candidate: current, policy: loginOriginPolicy
            )
        else {
            Log.engine.notice("refused a login fill: origin no longer matches")
            return .originMismatch
        }

        let script = LoginFormFiller.script(
            usernameFieldID: usernameFieldID, username: username,
            passwordFieldID: passwordFieldID, password: password
        )
        // Reduce to a String inside the callback: `Any?` is not Sendable, so
        // handing the raw result across the continuation trips strict
        // concurrency — and the script only ever returns JSON text anyway.
        let json: String? = await withCheckedContinuation { continuation in
            live.webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
        let filled = LoginFormFiller.result(from: json)
        guard filled.username || filled.password else { return .fieldsUnavailable }
        return .filled(username: filled.username, password: filled.password)
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

    // MARK: - Sleep timer

    public func setSleepTimer(after seconds: TimeInterval, paneID: UUID) {
        cancelSleepTimerWorkItem(paneID)
        let deadline = Date().addingTimeInterval(seconds)
        sleepTimers[paneID] = deadline
        if let live = pool.peek(paneID) {
            live.sleepTimerDeadline = deadline
            handleSnapshot(live.snapshot, for: paneID)
        }

        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fireSleepTimer(paneID: paneID)
            }
        }
        sleepTimerFires[paneID] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: workItem)
    }

    public func cancelSleepTimer(paneID: UUID) {
        guard sleepTimers[paneID] != nil else { return }
        cancelSleepTimerWorkItem(paneID)
        sleepTimers.removeValue(forKey: paneID)
        if let live = pool.peek(paneID) {
            live.sleepTimerDeadline = nil
            handleSnapshot(live.snapshot, for: paneID)
        }
    }

    /// Applies a pane's sleep timer to a freshly-built view (revive). Fires
    /// immediately when the deadline has already passed — a timer that ran out
    /// while the pane had no live view must still pause the restored page.
    func reapplySleepTimer(paneID: UUID) {
        guard let deadline = sleepTimers[paneID], let live = pool.peek(paneID) else {
            return
        }
        if deadline.timeIntervalSinceNow <= 0 {
            fireSleepTimer(paneID: paneID)
        } else {
            live.sleepTimerDeadline = deadline
        }
    }

    private func fireSleepTimer(paneID: UUID) {
        guard let deadline = sleepTimers[paneID] else { return }
        cancelSleepTimerWorkItem(paneID)

        guard let live = pool.peek(paneID) else {
            // No view to pause. The deadline is still owed, so keep it for the
            // revive path — `reapplySleepTimer` fires it the moment a view exists.
            sleepTimers[paneID] = deadline
            return
        }

        sleepTimers.removeValue(forKey: paneID)
        live.sleepTimerDeadline = nil
        live.webView.evaluateJavaScript(
            "\(SleepTimerController.pauseAllFunction)();", completionHandler: nil
        )
        handleSnapshot(live.snapshot, for: paneID)
    }

    private func cancelSleepTimerWorkItem(_ paneID: UUID) {
        if let item = sleepTimerFires.removeValue(forKey: paneID) {
            item.cancel()
        }
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

    #if DEBUG
    public func codecSupport(for paneID: UUID) async -> [CodecProbe]? {
        guard let webView = pool.view(for: paneID)?.webView else { return nil }

        var results: [CodecProbe] = []
        results.reserveCapacity(CodecCatalog.probes.count)
        for probe in CodecCatalog.probes {
            // Two checks, because they answer different questions and streaming
            // sites care about the second. `MediaSource.isTypeSupported` is
            // "can decode at all" (software or hardware). `mediaCapabilities`
            // additionally reports `powerEfficient` — "decodes in hardware" —
            // which is what YouTube gates AV1 on. A throw (page gone mid-probe)
            // reads as all-false, the honest default. The 2160p60 profile mirrors
            // what a 4K request would ask for, so `powerEfficient` reflects the
            // real hardware path, not a trivially-cheap tiny clip.
            let (supported, powerEfficient, smooth): (Bool, Bool, Bool)
            do {
                let value = try await webView.callAsyncJavaScript(
                    """
                    const supported = !!(window.MediaSource && MediaSource.isTypeSupported(type));
                    let powerEfficient = false, smooth = false;
                    if (navigator.mediaCapabilities) {
                        const info = await navigator.mediaCapabilities.decodingInfo({
                            type: "media-source",
                            video: { contentType: type, width: 3840, height: 2160,
                                     bitrate: 15000000, framerate: 60 }
                        });
                        powerEfficient = !!info.powerEfficient;
                        smooth = !!info.smooth;
                    }
                    return { supported, powerEfficient, smooth };
                    """,
                    arguments: ["type": probe.mimeType],
                    contentWorld: .defaultClient
                )
                let dict = value as? [String: Any]
                supported = (dict?["supported"] as? Bool) ?? false
                powerEfficient = (dict?["powerEfficient"] as? Bool) ?? false
                smooth = (dict?["smooth"] as? Bool) ?? false
            } catch {
                Log.engine.debug("codec probe failed: \(error.localizedDescription)")
                (supported, powerEfficient, smooth) = (false, false, false)
            }
            results.append(
                CodecProbe(
                    label: probe.label, mimeType: probe.mimeType,
                    isSupported: supported, isPowerEfficient: powerEfficient, isSmooth: smooth
                )
            )
        }
        return results
    }
    #endif

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
