import AppKit
import ChordCore
import Foundation
import WebKit

/// `chrome.identity.launchWebAuthFlow`: a real sign-in window for an OAuth
/// provider, closed the moment it reaches
/// `https://<extension-id>.chromiumapp.org/…`.
///
/// WebKit has no `chrome.identity`, and a provider that refuses embedded
/// web views (Google does) will not work inside the extension's popup. Chrome
/// therefore opens a browser window with the Space's cookies and watches only
/// for the extension's redirect address. This is the same shape, in a small
/// window Chord owns: HTTP(S) pages only, no extension scripts, no downloads,
/// and the answer is the redirect URL — never the provider's page.
@MainActor
final class ExtensionAuthWindow: NSObject, WKNavigationDelegate, NSWindowDelegate {
    enum Failure: LocalizedError {
        case declined, badURL, timedOut

        var errorDescription: String? {
            switch self {
            case .declined: "The user did not approve access."
            case .badURL: "The authorization page could not be loaded."
            case .timedOut: "The authorization flow timed out."
            }
        }
    }

    /// Chrome's redirect host for an extension. The path and query are the
    /// provider's, and are handed back untouched.
    static func isRedirect(_ url: URL, extensionID: String) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              let host = url.host()?.lowercased()
        else { return false }
        return host == "\(extensionID.lowercased()).chromiumapp.org"
    }

    private static var active: [String: ExtensionAuthWindow] = [:]

    static func run(
        url: URL, extensionID: String, dataStore: WKWebsiteDataStore,
        interactive: Bool = true
    ) async throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil
        else { throw Failure.badURL }

        // Chrome allows one flow per extension; a new one ends the last.
        active[extensionID]?.finish(.failure(Failure.declined))
        return try await withCheckedThrowingContinuation { continuation in
            let flow = ExtensionAuthWindow(
                extensionID: extensionID, url: url, dataStore: dataStore,
                interactive: interactive
            ) { result in
                active[extensionID] = nil
                continuation.resume(with: result)
            }
            active[extensionID] = flow
            flow.start()
        }
    }

    private let extensionID: String
    private let url: URL
    private let dataStore: WKWebsiteDataStore
    /// A visible window for a user-driven flow, a hidden view for
    /// `interactive: false` (Claude restores its sign-in that way at launch).
    private let interactive: Bool
    private var completion: ((Result<URL, Error>) -> Void)?
    private var window: NSWindow?
    private var web: WKWebView?
    private var deadline: Task<Void, Never>?
    private var finished = false

    private init(
        extensionID: String, url: URL, dataStore: WKWebsiteDataStore,
        interactive: Bool, finish: @escaping (Result<URL, Error>) -> Void
    ) {
        self.extensionID = extensionID
        self.url = url
        self.dataStore = dataStore
        self.interactive = interactive
        self.completion = finish
        super.init()
    }

    private func start() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        // Give the provider the browser's completed Safari token rather than
        // WKWebView's bare `(KHTML, like Gecko)` UA, which Google serves a
        // stripped-down page to. See `UserAgentPreference`.
        configuration.applicationNameForUserAgent = UserAgentPreference.safariVersionToken
        let web = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 520, height: 680),
            configuration: configuration
        )
        web.navigationDelegate = self
        self.web = web

        if interactive {
            let window = NSWindow(
                contentRect: web.frame,
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Sign in"
            window.contentView = web
            window.delegate = self
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.window = window
        }

        // Ten minutes with nobody finishing (one minute out of sight): the
        // tab's address is no longer watched for, and the extension is told
        // the flow failed.
        let limit: TimeInterval = interactive ? 600 : 60
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(Failure.timedOut))
        }
        web.load(URLRequest(url: url))
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        deadline = nil
        let done = completion
        completion = nil
        web?.navigationDelegate = nil
        web?.uiDelegate = nil
        window?.delegate = nil
        window?.close()
        window = nil
        web = nil
        done?(result)
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let target = navigationAction.request.url else { return .cancel }
        if Self.isRedirect(target, extensionID: extensionID) {
            // Nothing is ever loaded from chromiumapp.org.
            finish(.success(target))
            return .cancel
        }
        let scheme = target.scheme?.lowercased() ?? ""
        return ["http", "https", "about"].contains(scheme) ? .allow : .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(Failure.declined))
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        finish(.failure(Failure.declined))
    }
}
