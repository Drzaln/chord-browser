import Foundation
import Testing

@testable import ChordEngine

@Suite("Context link monitor")
struct ContextLinkMonitorTests {

    @Test("A web link body parses to its URL")
    func parsesWebLink() {
        #expect(ContextLinkMonitor.linkURL(from: "https://example.com/a") == URL(string: "https://example.com/a"))
        #expect(ContextLinkMonitor.linkURL(from: "http://example.com") == URL(string: "http://example.com"))
    }

    @Test("An empty body (no link under the click) is nil")
    func emptyIsNil() {
        #expect(ContextLinkMonitor.linkURL(from: "") == nil)
    }

    @Test("A non-web scheme is rejected, so the menu item never opens it")
    func rejectsNonWebSchemes() {
        #expect(ContextLinkMonitor.linkURL(from: "javascript:alert(1)") == nil)
        #expect(ContextLinkMonitor.linkURL(from: "file:///etc/passwd") == nil)
        #expect(ContextLinkMonitor.linkURL(from: "mailto:a@b.com") == nil)
    }

    @Test("A non-string body is nil")
    func nonStringIsNil() {
        #expect(ContextLinkMonitor.linkURL(from: 42) == nil)
    }
}
