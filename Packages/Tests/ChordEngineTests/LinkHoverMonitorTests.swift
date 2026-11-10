import Foundation
import Testing
import WebKit

@testable import ChordEngine

@Suite("Link hover monitor")
@MainActor
struct LinkHoverMonitorTests {

    @Test("A message body becomes a link, or nothing")
    func parsing() {
        #expect(LinkHoverMonitor.link(from: "https://example.com/a?b=1")?.host() == "example.com")
        #expect(LinkHoverMonitor.link(from: "mailto:someone@example.com")?.scheme == "mailto")
        #expect(LinkHoverMonitor.link(from: "") == nil)
        #expect(LinkHoverMonitor.link(from: 42) == nil)
        #expect(LinkHoverMonitor.link(from: "no scheme here") == nil)
        let long = "https://example.com/" + String(repeating: "a", count: LinkHoverMonitor.maxLength)
        #expect(LinkHoverMonitor.link(from: long) == nil)
    }

    @Test("The script sets no timer")
    func noTimers() {
        let source = LinkHoverMonitor.makeUserScript().source
        #expect(!source.contains("setInterval"))
        #expect(!source.contains("setTimeout"))
        #expect(!source.contains("requestAnimationFrame"))
    }

    /// Collects what the page posts.
    private final class Inbox: NSObject, WKScriptMessageHandler {
        var bodies: [String] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            bodies.append(message.body as? String ?? "?")
        }
    }

    @Test("In a real page: the resolved href on entering a link, once, and empty on leaving")
    func inAPage() async throws {
        let inbox = Inbox()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(inbox, name: LinkHoverMonitor.messageName)
        configuration.userContentController.addUserScript(LinkHoverMonitor.makeUserScript())
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.loadHTMLString(
            #"<p id="plain">text</p><a id="link" href="/go?x=1">Totally <b id="inner">safe</b></a>"#,
            baseURL: URL(string: "https://example.com/dir/")
        )
        for _ in 0..<100 {
            if try await web.evaluateJavaScript("!!document.getElementById('inner')") as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }

        func fire(_ type: String, on id: String, related: String = "null") async throws {
            _ = try await web.evaluateJavaScript(
                "document.getElementById('\(id)').dispatchEvent(new MouseEvent('\(type)', "
                    + "{bubbles: true, relatedTarget: \(related)})); 0")
        }
        // Onto the link's inner element, then across to the link itself: one report.
        try await fire("mouseover", on: "inner")
        try await fire("mouseover", on: "link")
        // Off the link, onto plain text.
        try await fire("mouseover", on: "plain")
        // Back on, then out of the document altogether.
        try await fire("mouseover", on: "link")
        try await fire("mouseout", on: "link")

        for _ in 0..<100 where inbox.bodies.count < 4 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(inbox.bodies == [
            "https://example.com/go?x=1", "", "https://example.com/go?x=1", "",
        ])
    }
}
