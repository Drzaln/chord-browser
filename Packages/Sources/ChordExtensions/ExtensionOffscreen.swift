import AppKit
import Foundation
import WebKit

/// A DOM owned by an extension, never a browser tab.
///
/// `chrome.offscreen` is one of the Chrome APIs WebKit does not provide. The
/// page is a real `WKWebView` built from the extension's own configuration, so
/// its scripts see `chrome.*`; it is registered with the extension context as
/// a tab with no place in any window, which is how WebKit finds content
/// scripts in its frames.
///
/// Milestone 1 creates, closes and reports a document. Message routing into
/// and out of the document — `chrome.runtime.sendMessage` reaching its
/// listeners — comes with the full shim in the next milestone.
@MainActor
final class ExtensionOffscreen: NSObject, WKNavigationDelegate, WKUIDelegate, WKWebExtensionTab {
    private struct Key: Hashable {
        let spaceID: UUID
        let identifier: String
    }

    private static var documents: [Key: ExtensionOffscreen] = [:]

    static func create(
        path: String, reasons: [String], context: WKWebExtensionContext,
        spaceID: UUID, capture: ExtensionCapture? = nil
    ) async throws {
        let key = Key(spaceID: spaceID, identifier: context.uniqueIdentifier)
        guard documents[key] == nil else {
            throw Failure.oneDocument
        }
        guard let url = URL(string: path, relativeTo: context.baseURL)?.absoluteURL,
              url.scheme == "chrome-extension",
              url.host == context.uniqueIdentifier,
              url.user == nil, url.password == nil,
              !url.path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
              let configuration = context.webViewConfiguration
        else { throw Failure.badURL }

        let preferences = configuration.preferences.copy() as? WKPreferences
        // Never suspended in its window, though: WebKit hides a suspending
        // page's content until its next frame, which a window never shown
        // doesn't draw, and the UI runs a display link meanwhile (c1k.11).
        preferences?.inactiveSchedulingPolicy = reasons.contains("AUDIO_PLAYBACK") ? .none : .throttle
        // An offscreen document has no window to focus, so WebKit would hold
        // its getUserMedia for ever. A document made to record is allowed to.
        if reasons.contains("USER_MEDIA"), let preferences {
            ExtensionCapture.set("_setGetUserMediaRequiresFocus:", false, in: preferences)
        }
        if let preferences { configuration.preferences = preferences }

        let document = ExtensionOffscreen(
            context: context, spaceID: spaceID, url: url,
            reasons: Set(reasons), configuration: configuration, capture: capture
        )
        documents[key] = document
        // WebKit needs a tab adapter to identify content scripts in this
        // page's frames. It is never inserted into a Space's tab row.
        context.didOpenTab(document)
        Log.extensions.debug(
            "creating offscreen document \(url.path) for \(context.uniqueIdentifier)"
        )
        do {
            try await document.load()
            Log.extensions.debug(
                "offscreen document ready for \(context.uniqueIdentifier)"
            )
        } catch {
            close(identifier: context.uniqueIdentifier, spaceID: spaceID)
            Log.extensions.error(
                "offscreen document failed for \(context.uniqueIdentifier): \(String(describing: error))"
            )
            throw error
        }
    }

    static func close(identifier: String, spaceID: UUID) {
        documents[Key(spaceID: spaceID, identifier: identifier)]?
            .close(error: Failure.closed)
    }

    static func hasDocument(identifier: String, spaceID: UUID) -> Bool {
        documents[Key(spaceID: spaceID, identifier: identifier)] != nil
    }

    static func url(identifier: String, spaceID: UUID) -> URL? {
        documents[Key(spaceID: spaceID, identifier: identifier)]?.web.url
    }

    /// Deliver a `chrome.runtime.sendMessage` to the offscreen page's shim.
    /// The full shim defines `__chordOffscreenDispatch`; a page without it is
    /// left unhandled rather than crashing the worker.
    static func send(
        _ message: Any, sender: [String: Any], token: String,
        identifier: String, spaceID: UUID
    ) async throws -> Any {
        guard !token.isEmpty, token.count <= 128,
              let document = documents[Key(spaceID: spaceID, identifier: identifier)]
        else { return ["handled": false] }
        return try await document.dispatch(message: message, sender: sender)
    }

    /// The live page, for tests and diagnostics. Internal: no WK* type leaves
    /// the extension package's own code.
    static func webView(identifier: String, spaceID: UUID) -> WKWebView? {
        documents[Key(spaceID: spaceID, identifier: identifier)]?.web
    }

    static func reasons(of web: WKWebView) -> Set<String>? {
        documents.values.first { $0.web === web }?.reasons
    }

    private let extensionContext: WKWebExtensionContext
    private let spaceID: UUID
    private let url: URL
    private let reasons: Set<String>
    private let capture: ExtensionCapture?
    private let web: WKWebView
    private var loading: CheckedContinuation<Void, Error>?
    private var deadline: Task<Void, Never>?
    private var ready = false
    private var closed = false
    /// The window an AUDIO_PLAYBACK document's view sits in, never shown:
    /// WebKit neither loads nor plays a page's media until its view is in a
    /// window (`play()` never settles), and Chrome's offscreen documents
    /// exist to play sounds. An extension that played one in answer to a
    /// click on a site stayed silent (se2).
    private var stage: NSWindow?

    private init(
        context: WKWebExtensionContext, spaceID: UUID, url: URL, reasons: Set<String>,
        configuration: WKWebViewConfiguration, capture: ExtensionCapture?
    ) {
        extensionContext = context
        self.spaceID = spaceID
        self.url = url
        self.reasons = reasons
        self.capture = capture
        web = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        )
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        if reasons.contains("AUDIO_PLAYBACK") {
            let window = OffscreenWindow()
            window.contentView = web
            stage = window
        }
    }

    private func load() async throws {
        try await withCheckedThrowingContinuation { continuation in
            loading = continuation
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.close(error: Failure.timeout)
            }
            web.load(URLRequest(url: url))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        deadline?.cancel()
        deadline = nil
        let continuation = loading
        loading = nil
        continuation?.resume(with: result)
    }

    private func close(error: Error) {
        guard !closed else { return }
        closed = true
        let key = Key(
            spaceID: spaceID, identifier: extensionContext.uniqueIdentifier
        )
        if Self.documents[key] === self { Self.documents[key] = nil }
        extensionContext.didCloseTab(self, windowIsClosing: false)
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.stopLoading()
        stage?.contentView = nil
        stage = nil
        finish(.failure(error))
    }

    private func dispatch(message: Any, sender: [String: Any]) async throws -> Any {
        try await web.callAsyncJavaScript(
            "return await globalThis.__chordOffscreenDispatch(message, sender);",
            arguments: ["message": message, "sender": sender],
            in: nil, contentWorld: .page
        ) ?? ["handled": false]
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closed, !ready else { return }
        ready = true
        finish(.success(()))
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { return .cancel }
        guard navigationAction.targetFrame?.isMainFrame != false else { return .allow }
        let to = navigationAction.request.url
        return to?.scheme == url.scheme && to?.host == url.host ? .allow : .cancel
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .cancel
    }

    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        if !ready { close(error: error) }
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        if !ready { close(error: error) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        close(error: Failure.processExited)
    }

    func webViewDidClose(_ webView: WKWebView) {
        close(error: Failure.closed)
    }

    /// Screen recording from an offscreen document: only while Chord's own
    /// call is in flight, never the extension's on its own.
    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func displayCapture(
        _ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo,
        systemAudio: Bool, decisionHandler: @escaping (Int) -> Void
    ) {
        decisionHandler(capture?.displayDecision(for: webView) ?? 0)
    }

    // MARK: - WKWebExtensionTab

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { nil }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func title(for context: WKWebExtensionContext) -> String? { web.title }
    func url(for context: WKWebExtensionContext) -> URL? { web.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !web.isLoading }
    func isSelected(for context: WKWebExtensionContext) -> Bool { false }

    func close(for context: WKWebExtensionContext) async throws {
        close(error: Failure.closed)
    }

    enum Failure: Error, LocalizedError, CustomStringConvertible {
        case oneDocument
        case badURL
        case timeout
        case closed
        case processExited

        var errorDescription: String? { description }

        var description: String {
            switch self {
            case .oneDocument: "Only a single offscreen document may be created."
            case .badURL: "The offscreen document must belong to this extension."
            case .timeout: "The offscreen document did not finish loading."
            case .closed: "The offscreen document was closed."
            case .processExited: "The offscreen document's web process exited."
            }
        }
    }
}

/// Holds an offscreen document's view so WebKit counts it as in a window.
/// Never ordered in, and never key or main, so nothing that looks for the
/// app's windows finds it.
private final class OffscreenWindow: NSWindow {
    init() {
        super.init(
            contentRect: CGRect(x: -10_000, y: -10_000, width: 800, height: 600),
            styleMask: .borderless, backing: .buffered, defer: true
        )
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
