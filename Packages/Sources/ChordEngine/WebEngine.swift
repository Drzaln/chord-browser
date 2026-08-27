import ChordCore
import Foundation

/// Everything the rest of the app is allowed to know about a loaded page.
///
/// No WebKit type appears here, or anywhere else in this package's public
/// interface — that is what keeps a WebKit API change to one package (7.1).
public struct PaneSnapshot: Equatable, Sendable {
    public var url: URL?
    public var title: String
    public var isLoading: Bool
    public var estimatedProgress: Double
    public var canGoBack: Bool
    public var canGoForward: Bool
    /// Drives the sweep's audio exemption (4.3). Observed from inside the page;
    /// see `MediaActivityMonitor`.
    public var isPlayingAudio: Bool
    /// Whether the page's audio is muted by the user (non-spec: user-requested).
    /// Engine-side state, not a `WKWebView` property — see `AudioMuteController`.
    public var isMuted: Bool

    /// When the pane's sleep timer fires, if one is armed (non-spec:
    /// user-requested). Engine-side state, not a `WKWebView` property — see
    /// `SleepTimerController`.
    public var sleepTimerDeadline: Date?

    /// Whether the page currently holds a `getDisplayMedia` stream, i.e. it is
    /// screen-sharing (non-spec: user-requested). WebKit reports no such state,
    /// so it is observed in-page; see `ScreenShareMonitor`.
    public var isScreenSharing: Bool

    /// The login fields this page is currently showing, if any (V3 of the
    /// password vault). Reported by `PasswordFormMonitor` and judged by
    /// `LoginFormClassifier` — WebKit has no notion of a login form.
    ///
    /// Nil until the page reports; `.none` once it has reported nothing fillable.
    /// The distinction matters to the UI: "not looked yet" is not "no form here".
    public var loginForm: LoginFormAnalysis?

    public init(
        url: URL? = nil,
        title: String = "",
        isLoading: Bool = false,
        estimatedProgress: Double = 0,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        isPlayingAudio: Bool = false,
        isMuted: Bool = false,
        sleepTimerDeadline: Date? = nil,
        isScreenSharing: Bool = false,
        loginForm: LoginFormAnalysis? = nil
    ) {
        self.loginForm = loginForm
        self.isPlayingAudio = isPlayingAudio
        self.isMuted = isMuted
        self.sleepTimerDeadline = sleepTimerDeadline
        self.isScreenSharing = isScreenSharing
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.estimatedProgress = estimatedProgress
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }
}

@MainActor
public protocol WebEngineDelegate: AnyObject {
    func paneDidUpdate(_ paneID: UUID, snapshot: PaneSnapshot)
    func paneDidLoadFavicon(_ paneID: UUID, data: Data?)
    /// A page thumbnail was captured (non-spec: user-requested, the Ctrl+Tab
    /// switcher). Carries the PNG; `nil` means the capture failed. The engine
    /// never caches — the store owns the thumbnails.
    func paneDidCaptureThumbnail(_ paneID: UUID, data: Data?)
    /// A page asked for a new window. The engine created a *real* popup web
    /// view first, so the page's `window.open()` call gets a live window
    /// reference and `window.close()` works — the two things OAuth flows
    /// depend on. The store must host it as a tab; `popupPaneID` is the pane
    /// the popup's web view is registered under, and is the id the tab's pane
    /// must carry so the tab surfaces that view.
    func paneRequestedPopup(url: URL?, popupPaneID: UUID, fromPane paneID: UUID?)
    /// A script popup (from `window.open()`) called `window.close()`. Only
    /// script-created windows can close themselves, so this identifies a popup
    /// tab: close it, so the auth popup the user just finished does not linger.
    func panePopupDidClose(_ paneID: UUID)
    /// A link's context menu asked to open it in the Little Chord panel (non-spec:
    /// user-requested).
    /// "Open Link in New Tab" from a link's context menu: a tab in the window
    /// showing that page, left in the background.
    func paneRequestedBackgroundTab(url: URL, fromPane paneID: UUID?)

    /// "Open Link in New Private Window" from a link's context menu.
    func paneRequestedPrivateWindow(url: URL)

    func paneRequestedLittleChord(url: URL)
    /// The user performed the "undo page" swipe (a two-finger rightward drag) on
    /// a pane that had nothing to undo — WebKit's native back/forward gesture
    /// did not navigate, so it fell through to our monitor. The store decides
    /// what that means: close the tab, or dismiss a Little Chord panel
    /// (non-spec: user-requested experiment).
    func paneRequestedSwipeClose(_ paneID: UUID)
    /// A plain left-click on a link inside a favourite/pinned tab (non-spec:
    /// user-requested). The store decides from the pane's tab placement whether
    /// to lift the navigation into the Peek panel; return true to cancel the
    /// navigation (the store presented the preview), false to let the click
    /// navigate the tab as usual.
    func paneRequestedPeek(url: URL, fromPane paneID: UUID) -> Bool
    /// A page called `new Notification(...)` — post it to Notification Center
    /// (non-spec: user-requested). Carries the pane so a click can focus its tab.
    func paneRequestedNotification(_ request: WebNotificationRequest, fromPane paneID: UUID)
    /// A login form was submitted, carrying what the user typed (V5 of the
    /// password vault). The store decides whether that is worth offering to
    /// save; **the engine never persists anything and never logs this.**
    func paneDidSubmitLogin(
        origin: String, username: String, password: String, fromPane paneID: UUID
    )
    /// A page called `Notification.requestPermission()`. Return whether to grant:
    /// the store consults its remembered per-origin decision and, the first time
    /// for a site, prompts the user (normal browser behaviour), then requests OS
    /// authorization as the delivery backstop.
    func paneRequestedNotificationPermission(_ prompt: SitePermissionPrompt) async -> Bool
    /// A page read `Notification.permission` at load — report the remembered
    /// per-origin decision (`default` when the site has not been asked) so the
    /// synchronous getter reflects a real choice without prompting.
    func paneNotificationPermissionState(
        origin: String, paneID: UUID?
    ) async -> WebNotificationPermission
    /// A page called `getUserMedia` for camera/microphone. Return whether to
    /// grant: the store consults its remembered per-origin decision and, the
    /// first time for a site, prompts the user (normal browser behaviour). This
    /// replaces the old blanket auto-grant.
    func paneRequestedMediaCapture(_ prompt: SitePermissionPrompt) async -> Bool
    /// A page asked for its location (`navigator.geolocation`). Return whether
    /// to grant: the store consults its remembered per-origin decision and, the
    /// first time for a site, prompts the user (normal browser behaviour), then
    /// the OS TCC gate decides whether Chord itself is location-aware.
    func paneRequestedGeolocation(_ prompt: SitePermissionPrompt) async -> Bool
    /// A page read the remembered geolocation decision (`navigator.permissions.query`
    /// or the shimmed `navigator.geolocation` at load) — report it without
    /// prompting so the synchronous read reflects a real choice.
    func paneGeolocationPermissionState(
        origin: String, paneID: UUID?
    ) async -> WebGeolocationPermission
    /// The content process died. The pane's model is intact; the view is gone.
    func paneContentProcessDidTerminate(_ paneID: UUID)
}

extension WebEngineDelegate {
    /// Defaults so delegates that predate these features (and test doubles) need
    /// not implement them.
    public func paneRequestedBackgroundTab(url: URL, fromPane paneID: UUID?) {}
    public func paneRequestedPopup(url: URL?, popupPaneID: UUID, fromPane paneID: UUID?) {}
    public func panePopupDidClose(_ paneID: UUID) {}
    public func paneRequestedPrivateWindow(url: URL) {}
    public func paneRequestedLittleChord(url: URL) {}
    public func paneRequestedSwipeClose(_ paneID: UUID) {}
    public func paneRequestedPeek(url: URL, fromPane paneID: UUID) -> Bool { false }
    public func paneRequestedNotification(_ request: WebNotificationRequest, fromPane paneID: UUID) {}
    public func paneRequestedNotificationPermission(_ prompt: SitePermissionPrompt) async -> Bool {
        false
    }
    public func paneNotificationPermissionState(
        origin: String, paneID: UUID?
    ) async -> WebNotificationPermission { .notDetermined }
public func paneRequestedMediaCapture(_ prompt: SitePermissionPrompt) async -> Bool {
        false
    }
    public func paneRequestedGeolocation(_ prompt: SitePermissionPrompt) async -> Bool {
        false
    }
    public func paneGeolocationPermissionState(
        origin: String, paneID: UUID?
    ) async -> WebGeolocationPermission { .notDetermined }
    public func paneDidSubmitLogin(
        origin: String, username: String, password: String, fromPane paneID: UUID
    ) {}
    public func paneDidCaptureThumbnail(_ paneID: UUID, data: Data?) {}
}

/// Why a fill did or did not happen. Distinguished because "we refused" and
/// "the page moved" call for different things being said to the user, and
/// because silently doing nothing is the failure mode a password manager must
/// never have.
public enum LoginFillOutcome: Equatable, Sendable {
    /// At least one field took the value.
    case filled(username: Bool, password: Bool)
    /// The pane is not showing the origin the credential belongs to. The
    /// interesting case: a page navigated between the offer and the click, so
    /// the credential would have gone to the wrong site.
    case originMismatch
    /// The fields are gone or no longer visible — a single-page app re-rendered,
    /// or the page hid them.
    case fieldsUnavailable
    /// No live web view for that pane.
    case noPane
}

/// The seam between the app and WebKit.
@MainActor
public protocol WebEngine: AnyObject {
    var delegate: (any WebEngineDelegate)? { get set }

    /// Supplies the per-Space web-extension controller attached to each new web
    /// view (M7). WebKit-free by design — the handle is opaque — so the Store
    /// can inject the host without importing WebKit. `nil` means no extensions,
    /// which is the state until one is loaded. See ADR 011.
    var extensionControllerProvider: (any ExtensionControllerProviding)? { get set }

    /// Returns a renderable surface, creating the underlying web view on first
    /// call. Never call this for a pane the user has not activated (6.2).
    ///
    /// The Space determines which `WKWebsiteDataStore` the view uses, so a pane
    /// created here can only ever see that Space's cookies.
    func surface(for pane: Pane, in space: Space) -> AnyWebSurface

    /// Deletes a Space's website data. Irreversible; prompt first (3.3).
    func removeData(for space: Space) async throws

    /// Clears the given website-data types (cache, cookies, site storage) from
    /// each Space's `WKWebsiteDataStore`, without deleting the stores themselves
    /// — the Spaces and their tabs stay, they just lose the selected data. Used
    /// by the settings "clear browsing data" surface. `history` is not a website
    /// data type and is ignored here; the Store clears it separately.
    func clearWebsiteData(_ types: BrowsingDataType, forSpaces spaces: [Space]) async

    func load(_ url: URL, in paneID: UUID)
    func goBack(in paneID: UUID)
    func goForward(in paneID: UUID)
    func reload(paneID: UUID)
    func stopLoading(paneID: UUID)

    /// Mutes or unmutes a pane's audio (non-spec: user-requested). Persists
    /// across reloads and view eviction so a muted tab stays muted.
    func setMuted(_ muted: Bool, paneID: UUID)

    /// Arms a sleep timer that pauses the pane's media when it fires (non-spec:
    /// user-requested). The deadline is tracked engine-side, so it survives
    /// reload and view eviction — the pause is applied to whatever view is live
    /// at fire time, and to a pane revived after its timer has run out. Re-arming
    /// replaces the pane's existing timer.
    func setSleepTimer(after seconds: TimeInterval, paneID: UUID)

    /// Cancels the pane's sleep timer, if one is armed.
    func cancelSleepTimer(paneID: UUID)

    /// Stops every display-capture stream the pane holds (non-spec:
    /// user-requested), ending screen sharing. A no-op for a pane with no live
    /// view — a page that is gone cannot be sharing. See `ScreenShareMonitor`.
    func stopScreenSharing(paneID: UUID)

    /// Sets the User-Agent policy: the global preference plus any per-domain
    /// overrides (§9.6). The engine resolves which one applies at the moment of
    /// navigation, since it is the only layer that sees the URL a request is
    /// actually going to. Applies to views built afterwards and to any already
    /// live. See `UserAgentRules`.
    func setUserAgent(_ global: UserAgentPreference, overrides: [UserAgentOverride])

    /// Sets whether the swipe-to-close experiment is on (non-spec:
    /// user-requested). When off, the engine stops watching for the "undo page"
    /// swipe and WebKit's native back/forward gesture is the only behaviour —
    /// a rightward swipe on a pane with no history simply does nothing.
    func setSwipeToCloseEnabled(_ enabled: Bool)

    /// Fills a credential into the fields the page reported (V4 of the password
    /// vault).
    ///
    /// `expectedOrigin` is checked against the pane's **current** URL inside the
    /// engine, immediately before writing. That re-check is the point: the offer
    /// was made against the origin at report time, and a page can navigate
    /// between the offer and the click. Trusting the caller's earlier decision is
    /// how a manager fills someone's bank password into whatever loaded next.
    ///
    /// Only ever called in response to a user gesture (threat-model rule 4).
    func fillLogin(
        paneID: UUID,
        expectedOrigin: String,
        usernameFieldID: String?,
        username: String,
        passwordFieldID: String?,
        password: String
    ) async -> LoginFillOutcome

    /// Fires the page-side `Notification` instance's `onclick` after its banner
    /// was clicked (non-spec: user-requested). A no-op if the pane has no live
    /// view — a closed page has nothing to notify.
    func dispatchNotificationClick(jsID: String, toPane paneID: UUID)

    func snapshot(for paneID: UUID) -> PaneSnapshot?

    /// Gives a live pane's web view keyboard focus, so page shortcuts — the
    /// spacebar, arrow keys — reach the page without a prior click into it.
    /// Tab switching moves the model's selection; making the web view the
    /// window's first responder is what makes those keys land on the page.
    ///
    /// Returns false when the pane has no live view or its view is not yet
    /// attached to a window, so the caller can retry once the surface is on
    /// screen.
    @discardableResult
    func focus(paneID: UUID) -> Bool

    /// Captures a page thumbnail for a live pane and reports it through
    /// `paneDidCaptureThumbnail` (non-spec: user-requested, the Ctrl+Tab
    /// switcher). A no-op for a pane with no live view — nothing to snapshot.
    /// Asynchronous: the result arrives on the delegate later, never from here.
    func captureThumbnail(for paneID: UUID)

    /// Presents the system print panel for a pane's page (M6). A no-op for a
    /// pane with no live view — you cannot print a page that was never shown.
    /// The `NSPrintOperation` stays inside this package; nothing WebKit- or
    /// AppKit-print-shaped crosses the seam.
    func printPane(paneID: UUID)

    /// Find-in-page (§8, M6). Returns whether a match was found, and scrolls
    /// the page to it.
    ///
    /// A `Bool` because that is genuinely all WebKit reports: `WKFindResult`
    /// carries `matchFound` and nothing else — no match count, no index of the
    /// current one. "3 of 12" cannot be built on the public API, so the find
    /// bar does not pretend to.
    func find(_ text: String, in paneID: UUID, backwards: Bool) async -> Bool

    /// Drops the find selection, so dismissing the bar does not leave the page
    /// highlighted.
    func clearFind(in paneID: UUID)

    /// Captures `interactionState`, tears the view down, keeps nothing else.
    @discardableResult
    func evict(paneID: UUID) -> Data?
    func evictAll()

    /// Drops every engine-side state a pane no longer needs because it is
    /// truly gone — a closed tab, a swept tab, a closed split pane, a deleted
    /// Space, a ended private session. Clears the interaction-state cache, the
    /// last-known URL, the context-link URL, the mute flag, and any sleep
    /// timer. Never call for a pane that still exists but was merely unloaded
    /// (favourite/pinned close): its cached state is what lets it revive
    /// without a reload.
    func forget(paneID: UUID)

    /// `interactionState` for a pane that is still live, without disturbing it.
    ///
    /// This is what makes restore worth anything: `evict` only yields state for
    /// panes that happened to be evicted, so a tab the user simply switched away
    /// from would otherwise be persisted with nothing to restore from.
    func interactionState(for paneID: UUID) -> Data?

    /// Whether a pane currently owns a web view. Restore is lazy, so for most
    /// panes this is false and must stay that way (6.2).
    func hasLiveView(paneID: UUID) -> Bool

    /// Seeds the state a pane should restore from before its view is built.
    /// Ignored once the view exists — restoring into a live view would throw
    /// away whatever the user has since done in it.
    func seedInteractionState(_ data: Data, for paneID: UUID)

    func liveViewCount() -> Int

    /// Turns developer-mode on or off (non-spec: user-requested). When on, the
    /// engine sets `developerExtrasEnabled` on every web view, which is what
    /// makes WebKit show the "Inspect Element" context menu and lets
    /// `showInspector` open the detached inspector window. When off (the
    /// default, including release builds) neither happens. Applied to views
    /// built afterwards and to any already live.
    func setDeveloperMode(_ enabled: Bool)

    /// Sets the full-page zoom factor applied to every web view (non-spec:
    /// user-requested), via `WKWebView.pageZoom`. Applied to views built
    /// afterwards and to any already live. Clamped onto the `PageZoom` ladder.
    func setPageZoom(_ factor: Double)

    /// Opens the Web Inspector for a pane's live view (non-spec:
    /// user-requested). The inspector is always a detached window in a
    /// `WKWebView` app. A no-op unless developer mode is on and the pane has a
    /// live view — the two things that gate whether an inspector exists.
    func showInspector(for paneID: UUID)

    /// DRM / streaming-capability diagnostic (non-spec: user-requested), for
    /// the pane's live view. Answers "does Chord's engine + this display chain
    /// actually support the profiles Netflix serves" — HEVC/HDR10, Dolby Vision,
    /// the surround audio codecs — plus the live media/EME errors the page has
    /// raised. `nil` when the pane has no live view. Surfaced by the DRM
    /// Diagnostics panel (Develop menu).
    func mediaDiagnostics(for paneID: UUID) async -> MediaDiagnostics?

#if DEBUG
    /// Developer diagnostic (non-spec): how many captured interaction-state
    /// blobs are held in memory vs. the LRU cap, plus how many panes the engine
    /// has been asked to forget. The first number being flat while tabs open and
    /// close is the proof that closed tabs stop leaking state (A2). Surfaced by
    /// the Cmd+Ctrl+P overlay. Compiled out of release.
    func interactionStateDiagnostics() -> (cached: Int, cap: Int, forgotten: Int)
    #endif
}

extension WebEngine {
    /// Defaults so test doubles and any non-WebKit engine need not implement
    /// the dev-mode and zoom plumbing; only `WebKitEngine` gives real behaviour.
    public func setDeveloperMode(_ enabled: Bool) {}
    public func setPageZoom(_ factor: Double) {}
    public func showInspector(for paneID: UUID) {}
    public func mediaDiagnostics(for paneID: UUID) async -> MediaDiagnostics? { nil }
}

#if DEBUG
extension WebEngine {
    /// Default so test doubles and any non-WebKit engine need not implement the
    /// diagnostic; only `WebKitEngine` gives a real answer.
    public func interactionStateDiagnostics() -> (cached: Int, cap: Int, forgotten: Int) {
        (0, 0, 0)
    }
}
#endif

/// One codec-support probe result. WebKit-free, like every other type crossing
/// this seam.
///
/// `isSupported` is `MediaSource.isTypeSupported` — "can decode at all", software
/// or hardware. `isPowerEfficient` is `mediaCapabilities.decodingInfo`'s flag —
/// "decodes in hardware". The gap between them is the whole answer to why YouTube
/// serves VP9 here but AV1 in Safari: sites choose AV1 only when it is reported
/// power-efficient, and a WKWebView can decode AV1 (supported = true) while still
/// reporting it as not power-efficient (no hardware path exposed to this process).
public struct CodecProbe: Sendable, Equatable {
    public let label: String
    public let mimeType: String
    public let isSupported: Bool
    public let isPowerEfficient: Bool
    public let isSmooth: Bool

    public init(
        label: String,
        mimeType: String,
        isSupported: Bool,
        isPowerEfficient: Bool,
        isSmooth: Bool
    ) {
        self.label = label
        self.mimeType = mimeType
        self.isSupported = isSupported
        self.isPowerEfficient = isPowerEfficient
        self.isSmooth = isSmooth
    }
}

/// One HDCP display-chain probe result (DRM diagnostic). WebKit-free.
///
/// `available` is `mediaCapabilities.decodingInfo(..., hdcp: "hdcp-<level>")`'s
/// `supported` flag. When the highest level is unavailable, the display chain —
/// a dock, an HDMI adapter, a non-HDCP monitor — silently caps DRM streams at
/// that resolution/quality, which is precisely how a DisplayLink dock or a
/// non-HDCP adapter shows Netflix at 720p with no error.
public struct HDCPProbe: Sendable, Equatable {
    public let level: String
    public let available: Bool

    public init(level: String, available: Bool) {
        self.level = level
        self.available = available
    }
}

/// The full DRM / streaming-capability report for one pane (non-spec:
/// user-requested). WebKit-free, so it crosses the seam into the UI and the
/// store without leaking WebKit. `nil` codec/hdcp arrays mean the probe was not
/// run (no live view); the error fields are what the page's own media elements
/// have raised, not something WebKit reports directly.
public struct MediaDiagnostics: Sendable, Equatable {
    public var codecs: [CodecProbe]
    public var hdcp: [HDCPProbe]
    /// The last media-element error text/code the pane's page raised, if any.
    public var lastMediaError: String?
    /// Whether the page has started an EME session (i.e. is actually using DRM).
    public var hasEMESession: Bool

    public init(
        codecs: [CodecProbe],
        hdcp: [HDCPProbe],
        lastMediaError: String?,
        hasEMESession: Bool
    ) {
        self.codecs = codecs
        self.hdcp = hdcp
        self.lastMediaError = lastMediaError
        self.hasEMESession = hasEMESession
    }
}

/// The codec strings Chord probes, chosen to answer the DRM/streaming question:
/// the profiles Netflix actually serves (HEVC/HDR10 4K, Dolby Vision, AC-3,
/// E-AC-3, AAC) plus the streaming baselines (AV1, VP9, HEVC, H.264). The
/// `codecs=` parameters are representative profiles, enough for
/// `MediaSource.isTypeSupported` to answer for the family.
public enum CodecCatalog {
    public static let probes: [(label: String, mimeType: String)] = [
        ("HEVC 4K HDR (hvc1)", #"video/mp4; codecs="hvc1.1.6.L153.B0""#),
        ("Dolby Vision (dvhe)", #"video/mp4; codecs="dvhe.05.06""#),
        ("Dolby Vision (dvh1)", #"video/mp4; codecs="dvh1.05.06""#),
        ("AC-3 5.1", #"audio/mp4; codecs="ac-3""#),
        ("E-AC-3 5.1/7.1", #"audio/mp4; codecs="ec-3""#),
        ("AAC", #"audio/mp4; codecs="mp4a.40.2""#),
        ("AV1", #"video/mp4; codecs="av01.0.05M.08""#),
        ("VP9", #"video/webm; codecs="vp09.00.10.08""#),
        ("HEVC (hvc1)", #"video/mp4; codecs="hvc1.1.6.L93.B0""#),
        ("H.264", #"video/mp4; codecs="avc1.42E01E""#),
    ]

    /// The HDCP display-chain levels probed, low to high. The highest that
    /// reports available is the ceiling the current display chain can do.
    public static let hdcpLevels: [String] = ["1.4", "2.2", "2.3"]
}
