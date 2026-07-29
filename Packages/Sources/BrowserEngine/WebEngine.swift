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

    public init(
        url: URL? = nil,
        title: String = "",
        isLoading: Bool = false,
        estimatedProgress: Double = 0,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        isPlayingAudio: Bool = false,
        isMuted: Bool = false,
        isScreenSharing: Bool = false
    ) {
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
    /// A page called `Notification.requestPermission()` — ask the OS and report
    /// whether notifications are allowed (non-spec: user-requested).
    func paneRequestedNotificationPermission() async -> Bool
    /// The content process died. The pane's model is intact; the view is gone.
    func paneContentProcessDidTerminate(_ paneID: UUID)
}

extension WebEngineDelegate {
    /// Defaults so delegates that predate these features (and test doubles) need
    /// not implement them.
    public func paneRequestedLittleArc(url: URL) {}
    public func paneRequestedPeek(url: URL?) {}
    public func paneRequestedNotification(_ request: WebNotificationRequest, fromPane paneID: UUID) {}
    public func paneRequestedNotificationPermission() async -> Bool { false }
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
}
