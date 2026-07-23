import AppKit
import Foundation
import WebKit

/// One live web view and the observations attached to it.
///
/// Every `WKWebView` costs a content process, a networking allocation, and
/// GPU-backed layers, so instances of this class are the app's dominant memory
/// cost and are handed out only through the pool.
@MainActor
final class LiveWebView {
    let paneID: UUID
    let webView: WKWebView
    let container: WebSurfaceContainerView

    private(set) var snapshot = PaneSnapshot()
    private var observations: [NSKeyValueObservation] = []

    /// Reported by the page rather than by WebKit; see `MediaActivityMonitor`.
    var isPlayingAudio = false {
        didSet { refreshSnapshot() }
    }

    init(paneID: UUID, webView: WKWebView, cornerRadius: CGFloat) {
        self.paneID = paneID
        self.webView = webView
        self.container = WebSurfaceContainerView(cornerRadius: cornerRadius)
        container.install(webView)
    }

    /// - Parameter onChange: invoked on the main actor whenever an observed
    ///   property moves. Held strongly by the observations, so the owner must
    ///   pass a closure that captures the engine weakly.
    func startObserving(onChange: @escaping @MainActor (UUID, PaneSnapshot) -> Void) {
        func observe<Value>(_ keyPath: KeyPath<WKWebView, Value>) {
            let observation = webView.observe(keyPath, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshSnapshot()
                    onChange(self.paneID, self.snapshot)
                }
            }
            observations.append(observation)
        }

        observe(\.title)
        observe(\.url)
        observe(\.isLoading)
        observe(\.estimatedProgress)
        observe(\.canGoBack)
        observe(\.canGoForward)

        refreshSnapshot()
    }

    func refreshSnapshot() {
        snapshot = PaneSnapshot(
            url: webView.url,
            title: webView.title ?? "",
            isLoading: webView.isLoading,
            estimatedProgress: webView.estimatedProgress,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            isPlayingAudio: isPlayingAudio
        )
    }

    /// `WKWebView.interactionState` is typed `Any?` but is a property-list blob;
    /// persisting it is how an evicted pane comes back without a reload.
    var interactionState: Data? {
        webView.interactionState as? Data
    }

    func restore(interactionState data: Data) {
        webView.interactionState = data
    }

    /// Explicit teardown. KVO observations and the delegate wiring are classic
    /// retain-cycle sources, so nothing here is left to deinit ordering.
    func tearDown() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        // A script message handler retains its receiver until removed, which is
        // one of the two classic leak sources named in 6.7.
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: MediaActivityMonitor.messageName)
        webView.stopLoading()
        container.removeContent()
    }

    deinit {
        // Observations invalidate themselves on dealloc; tearDown() is still the
        // supported path because it also unhooks the delegates.
        observations.forEach { $0.invalidate() }
    }
}

/// Least-recently-used cache of live web views.
@MainActor
final class WebViewPool {
    /// Steady-state cap (6.2).
    private(set) var capacity: Int
    private let defaultCapacity: Int

    private var live: [UUID: LiveWebView] = [:]
    /// Most-recently-used last.
    private var usageOrder: [UUID] = []

    private var pressureSource: DispatchSourceMemoryPressure?

    /// Called with a pane that is about to be torn down, so the owner can
    /// persist its `interactionState` first.
    var willEvict: ((UUID, Data?) -> Void)?

    init(capacity: Int = 12) {
        self.capacity = capacity
        self.defaultCapacity = capacity
        startWatchingMemoryPressure()
    }

    var count: Int { live.count }

    func view(for paneID: UUID) -> LiveWebView? {
        guard let view = live[paneID] else { return nil }
        touch(paneID)
        return view
    }

    func contains(_ paneID: UUID) -> Bool { live[paneID] != nil }

    /// Reads a live view without counting as a use. Capturing interactionState
    /// must not reorder the LRU — persisting every pane on quit would otherwise
    /// rewrite the eviction order for no reason.
    func peek(_ paneID: UUID) -> LiveWebView? { live[paneID] }

    func insert(_ view: LiveWebView) {
        live[view.paneID] = view
        touch(view.paneID)
        enforceCapacity()
    }

    func paneID(matching webView: WKWebView) -> UUID? {
        live.first { $0.value.webView === webView }?.key
    }

    func touch(_ paneID: UUID) {
        usageOrder.removeAll { $0 == paneID }
        usageOrder.append(paneID)
    }

    @discardableResult
    func evict(_ paneID: UUID) -> Data? {
        guard let view = live.removeValue(forKey: paneID) else { return nil }
        usageOrder.removeAll { $0 == paneID }

        let state = view.interactionState
        willEvict?(paneID, state)
        view.tearDown()
        Log.engine.debug("evicted pane \(paneID, privacy: .public), \(self.live.count) live")
        return state
    }

    func evictAll() {
        for paneID in usageOrder.reversed() { evict(paneID) }
    }

    /// Never evicts the pane the user is looking at.
    private var protectedPaneID: UUID? { usageOrder.last }

    private func enforceCapacity() {
        while live.count > capacity {
            guard let victim = usageOrder.first, victim != protectedPaneID else { return }
            evict(victim)
        }
    }

    // MARK: - Memory pressure

    /// Drop to 3 live views on `.critical`, 6 on `.warning`, and recover the
    /// steady-state cap once pressure clears (6.2).
    private func startWatchingMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical, .normal], queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, let source = self.pressureSource else { return }
            let event = source.data

            if event.contains(.critical) {
                self.applyCapacity(3, reason: "critical")
            } else if event.contains(.warning) {
                self.applyCapacity(6, reason: "warning")
            } else {
                self.capacity = self.defaultCapacity
                Log.engine.notice("memory pressure normal, capacity restored")
            }
        }
        source.resume()
        pressureSource = source
    }

    private func applyCapacity(_ newValue: Int, reason: String) {
        Log.engine.notice(
            "memory pressure \(reason, privacy: .public), capping live views at \(newValue)"
        )
        capacity = newValue
        enforceCapacity()
    }

    deinit {
        pressureSource?.cancel()
    }
}
