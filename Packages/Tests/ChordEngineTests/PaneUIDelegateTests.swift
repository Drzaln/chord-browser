import Foundation
import Testing
import WebKit

@testable import ChordEngine

/// 2nz: Google Meet offered entire screens only. WebKit gives a page the Mac's
/// full picker (screens and windows) only when the UI delegate does not
/// respond to the display-capture selector; a delegate that does respond can
/// answer screens or windows, never both.
@Suite("Pane UI delegate")
@MainActor
struct PaneUIDelegateTests {
    private let displayCapture = PaneUIDelegate.displayCaptureSelector
    private let mediaCapture = NSSelectorFromString(
        "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:"
    )

    private func makeEngine() -> WebKitEngine {
        WebKitEngine(configuration: EngineConfiguration(
            faviconCacheDirectory: URL(fileURLWithPath: "/tmp/engine-tests")
        ))
    }

    private func load(_ webView: WKWebView, at base: String) async {
        webView.loadHTMLString("<p>page</p>", baseURL: URL(string: base))
        for _ in 0..<100 where webView.url?.host == nil || webView.isLoading {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test("A website's delegate does not answer display capture")
    func aWebsiteKeepsTheFullPicker() async {
        let engine = makeEngine()
        let coordinator = NavigationCoordinator(engine: engine)
        let webView = WKWebView(frame: .zero)
        let delegate = PaneUIDelegate(coordinator: coordinator, webView: webView)
        webView.uiDelegate = delegate
        await load(webView, at: "https://meet.google.com/abc-defg-hij")

        // The coordinator has the method; handed to WebKit as the delegate it
        // would turn the picker into screens only.
        #expect(webView.url?.host == "meet.google.com")
        #expect(coordinator.responds(to: displayCapture))
        let asked = try? #require(webView.uiDelegate as? NSObject)
        #expect(asked?.responds(to: displayCapture) == false)
    }

    @Test("Everything else is the coordinator's")
    func otherQuestionsReachTheCoordinator() {
        let engine = makeEngine()
        let coordinator = NavigationCoordinator(engine: engine)
        let webView = WKWebView(frame: .zero)
        let delegate = PaneUIDelegate(coordinator: coordinator, webView: webView)

        #expect(delegate.responds(to: mediaCapture))
        #expect(delegate.forwardingTarget(for: mediaCapture) as? NavigationCoordinator === coordinator)
        #expect(!delegate.responds(to: NSSelectorFromString("noSuchDelegateMethod:")))
    }

    @Test("Only extension schemes are answered")
    func schemes() {
        #expect(PaneUIDelegate.answersDisplayCapture(for: URL(string: "chrome-extension://abc/p.html")))
        #expect(PaneUIDelegate.answersDisplayCapture(for: URL(string: "webkit-extension://abc/p.html")))
        #expect(!PaneUIDelegate.answersDisplayCapture(for: URL(string: "https://meet.google.com/")))
        #expect(!PaneUIDelegate.answersDisplayCapture(for: URL(string: "about:blank")))
        #expect(!PaneUIDelegate.answersDisplayCapture(for: nil))
    }
}
