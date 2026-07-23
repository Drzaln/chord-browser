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

    private let pool: WebViewPool
    private let favicons: FaviconLoader
    private let configuration: EngineConfiguration

    // BROWSER_SPEC 6.2 asks for a shared WKProcessPool. Apple deprecated the
    // whole type in macOS 12 — "Creating and using multiple instances of
    // WKProcessPool no longer has any effect" — so process sharing is now
    // governed by the data store, not by us. Setting it would only buy a
    // deprecation warning, and we build warnings-as-errors. See ADR 004.

    private var coordinator: NavigationCoordinator?

    /// Retained so an evicted or crashed pane can be revived without the model
    /// layer having to hand its state back.
    private var interactionStates: [UUID: Data] = [:]
    /// Last known URL per pane, for reload-after-crash.
    private var lastKnownURL: [UUID: URL] = [:]

    public init(configuration: EngineConfiguration) {
        self.configuration = configuration
        self.pool = WebViewPool(capacity: configuration.liveViewCapacity)
        self.favicons = FaviconLoader(cacheDirectory: configuration.faviconCacheDirectory)

        self.coordinator = NavigationCoordinator(engine: self)
        self.pool.willEvict = { [weak self] paneID, state in
            guard let self, let state else { return }
            self.interactionStates[paneID] = state
        }
    }

    // MARK: - Surfaces

    public func surface(for pane: Pane) -> AnyWebSurface {
        let live = liveView(for: pane)
        return AnyWebSurface(id: pane.id, container: live.container)
    }

    private func liveView(for pane: Pane) -> LiveWebView {
        if let existing = pool.view(for: pane.id) { return existing }

        let webView = makeWebView()
        let live = LiveWebView(
            paneID: pane.id, webView: webView, cornerRadius: configuration.cornerRadius
        )
        live.startObserving { [weak self] paneID, snapshot in
            self?.handleSnapshot(snapshot, for: paneID)
        }
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

    private func makeWebView() -> WKWebView {
        // Copying a template is cheaper than rebuilding a configuration, and
        // rebuilding recompiles content rule lists (6.2).
        let config = Self.configurationTemplate.copy() as! WKWebViewConfiguration
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.customUserAgent = nil
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        return webView
    }

    private static let configurationTemplate: WKWebViewConfiguration = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        return config
    }()

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

    // MARK: - Lifecycle

    @discardableResult
    public func evict(paneID: UUID) -> Data? {
        let state = pool.evict(paneID)
        if let state { interactionStates[paneID] = state }
        return state
    }

    public func evictAll() { pool.evictAll() }

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
}
