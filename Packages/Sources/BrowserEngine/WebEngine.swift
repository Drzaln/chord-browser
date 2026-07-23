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

    public init(
        url: URL? = nil,
        title: String = "",
        isLoading: Bool = false,
        estimatedProgress: Double = 0,
        canGoBack: Bool = false,
        canGoForward: Bool = false
    ) {
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
    func paneRequestedNewTab(url: URL)
    /// The content process died. The pane's model is intact; the view is gone.
    func paneContentProcessDidTerminate(_ paneID: UUID)
}

/// The seam between the app and WebKit.
@MainActor
public protocol WebEngine: AnyObject {
    var delegate: (any WebEngineDelegate)? { get set }

    /// Returns a renderable surface, creating the underlying web view on first
    /// call. Never call this for a pane the user has not activated (6.2).
    func surface(for pane: Pane) -> AnyWebSurface

    func load(_ url: URL, in paneID: UUID)
    func goBack(in paneID: UUID)
    func goForward(in paneID: UUID)
    func reload(paneID: UUID)
    func stopLoading(paneID: UUID)

    func snapshot(for paneID: UUID) -> PaneSnapshot?

    /// Captures `interactionState`, tears the view down, keeps nothing else.
    @discardableResult
    func evict(paneID: UUID) -> Data?
    func evictAll()

    func liveViewCount() -> Int
}
