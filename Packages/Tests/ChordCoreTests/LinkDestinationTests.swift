import Foundation
import Testing

@testable import ChordCore

@Suite("Link destination")
struct LinkDestinationTests {
    @Test("An address is shown whole")
    func whole() {
        let url = URL(string: "https://example.com/path?q=1#top")!
        #expect(LinkDestination.display(url) == "https://example.com/path?q=1#top")
    }

    @Test("A javascript: link shows its scheme only")
    func javascript() {
        #expect(LinkDestination.display(URL(string: "javascript:void(0)")!) == "javascript:")
        #expect(LinkDestination.display(URL(string: "JavaScript:alert(1)")!) == "javascript:")
    }

    @Test("A very long address is bounded")
    func bounded() {
        let long = URL(string: "https://example.com/" + String(repeating: "a", count: 1500))!
        #expect(LinkDestination.display(long).count == 512)
    }
}
