import Foundation
import Testing

@testable import BrowserEngine

@Suite("Peek link monitor")
struct PeekLinkMonitorTests {

    @Test("A web link parses to its URL")
    func parsesWebLink() {
        #expect(PeekLinkMonitor.linkURL(from: "https://example.com/x") == URL(string: "https://example.com/x"))
    }

    @Test("An empty body dismisses the preview")
    func emptyIsNil() {
        #expect(PeekLinkMonitor.linkURL(from: "") == nil)
    }

    @Test("Non-web schemes are rejected")
    func rejectsNonWeb() {
        #expect(PeekLinkMonitor.linkURL(from: "javascript:void(0)") == nil)
        #expect(PeekLinkMonitor.linkURL(from: "file:///x") == nil)
    }
}
