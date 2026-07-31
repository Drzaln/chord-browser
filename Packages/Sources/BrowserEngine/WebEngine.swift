import BrowserCore
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
        isScreenSharing: Bool = false,
        loginForm: LoginFormAnalysis? = nil
    ) {
        self.loginForm = loginForm
        self.isPlayingAudio = isPlayingAudio
        self.isMuted = isMuted
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
    /// `target="_blank"` / `window.open()`. Carries the pane that asked so the
    /// store can open the tab in the window actually showing that page.
    func paneRequestedNewTab(url: URL, fromPane paneID: UUID?)
    /// A link's context menu asked to open it in the Little Arc panel (non-spec:
    /// user-requested).
    func paneRequestedLittleArc(url: URL)
    /// The ⌘-hover Peek preview should show `url`, or dismiss when `nil`
    /// (non-spec: user-requested).
    func paneRequestedPeek(url: URL?)
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
    /// The content process died. The pane's model is intact; the view is gone.
    func paneContentProcessDidTerminate(_ paneID: UUID)
}

extension WebEngineDelegate {
    /// Defaults so delegates that predate these features (and test doubles) need
    /// not implement them.
    public func paneRequestedLittleArc(url: URL) {}
    public func paneRequestedPeek(url: URL?) {}
    public func paneRequestedNotification(_ request: WebNotificationRequest, fromPane paneID: UUID) {}
    public func paneRequestedNotificationPermission(_ prompt: SitePermissionPrompt) async -> Bool {
        false
    }
    public func paneNotificationPermissionState(
        origin: String, paneID: UUID?
    ) async -> WebNotificationPermission { .notDetermined }
    public func paneRequestedMediaCapture(_ prompt: SitePermissionPrompt) async -> Bool { false }
    public func paneDidSubmitLogin(
        origin: String, username: String, password: String, fromPane paneID: UUID
    ) {}
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

    /// Stops every display-capture stream the pane holds (non-spec:
    /// user-requested), ending screen sharing. A no-op for a pane with no live
    /// view — a page that is gone cannot be sharing. See `ScreenShareMonitor`.
    func stopScreenSharing(paneID: UUID)

    /// Sets the User-Agent every web view presents (non-spec: user-requested),
    /// or `nil` to restore the browser's own completed Safari UA. Applies to
    /// views built afterwards and to any already live (they take effect on the
    /// next load). See `UserAgentPreference`.
    func setCustomUserAgent(_ userAgent: String?)

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

    #if DEBUG
    /// Developer diagnostic (non-spec): whether this engine's WebKit advertises
    /// decode support for a set of media codec strings, via
    /// `MediaSource.isTypeSupported` run in the pane's live view. `nil` when the
    /// pane has no live view. The result is a property of the WebKit build and
    /// the host's hardware, not of the document, so it answers "does Chord get
    /// offered AV1/VP9/HEVC?" directly — the question behind streaming quality on
    /// Reels/Shorts. Surfaced by the Cmd+Ctrl+P overlay. Compiled out of release.
    func codecSupport(for paneID: UUID) async -> [CodecProbe]?
    #endif
}

#if DEBUG
extension WebEngine {
    /// Default so test doubles and any non-WebKit engine need not implement the
    /// diagnostic; only `WebKitEngine` gives a real answer.
    public func codecSupport(for paneID: UUID) async -> [CodecProbe]? { nil }
}

/// One codec-support probe result (DEBUG diagnostic). WebKit-free, like every
/// other type crossing this seam.
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

/// The codec strings Chord probes, chosen to answer the streaming-quality
/// question: AV1 (Instagram/Facebook Reels' high-efficiency ladder), VP9
/// (YouTube), then HEVC and H.264 (the WebKit-native baseline that Meta falls
/// back to). The `codecs=` parameters are representative profiles, enough for
/// `MediaSource.isTypeSupported` to answer for the family.
public enum CodecCatalog {
    public static let probes: [(label: String, mimeType: String)] = [
        ("AV1", #"video/mp4; codecs="av01.0.05M.08""#),
        ("VP9", #"video/webm; codecs="vp09.00.10.08""#),
        ("HEVC", #"video/mp4; codecs="hvc1.1.6.L93.B0""#),
        ("H.264", #"video/mp4; codecs="avc1.42E01E""#),
    ]
}
#endif
