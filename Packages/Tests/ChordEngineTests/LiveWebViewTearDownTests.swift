import WebKit
import Testing

@testable import ChordEngine

/// Evicting a pane must end its page, not just hide it: anything that still
/// holds the view (a pending script call, an opener, an extension) would
/// otherwise keep the old document's timers and network running.
@Suite("Live web view teardown")
@MainActor
struct LiveWebViewTearDownTests {

    private final class Counter: NSObject, WKScriptMessageHandler {
        var count = 0
        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            MainActor.assumeIsolated { count += 1 }
        }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<60 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test("Teardown replaces the page and silences its handlers")
    func teardownEndsThePage() async throws {
        let counter = Counter()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(counter, name: "tick")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let live = LiveWebView(paneID: UUID(), webView: webView, cornerRadius: 10)
        webView.loadHTMLString(
            "<script>setInterval(() => webkit.messageHandlers.tick.postMessage(1), 20)</script>",
            baseURL: URL(string: "https://example.com/")
        )
        #expect(await eventually { counter.count >= 3 })

        live.tearDown()

        // The old order cancelled its own about:blank load, so the document
        // lived on (`webView.url` alone reads the provisional URL and can't tell).
        var href: String?
        for _ in 0..<60 {
            href = try? await webView.evaluateJavaScript("location.href") as? String
            if href == "about:blank" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(href == "about:blank")
        let settled = counter.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(counter.count == settled, "no handler hears the old page any more")
    }
}
