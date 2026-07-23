import BrowserCore
import Foundation
import Testing

@Suite("Address bar input")
struct URLInputTests {

    @Test("A full URL is used as typed", arguments: [
        "https://example.com",
        "http://example.com/path?q=1",
        "file:///tmp/index.html",
    ])
    func passesThroughFullURLs(input: String) {
        #expect(URLInput.resolve(input)?.absoluteString == input)
    }

    @Test("A bare host gets https", arguments: [
        "example.com",
        "news.ycombinator.com/newest",
        "localhost",
    ])
    func upgradesBareHosts(input: String) {
        let resolved = URLInput.resolve(input)
        #expect(resolved?.scheme == "https")
        #expect(resolved?.absoluteString == "https://\(input)")
    }

    @Test("Anything with a space is a search")
    func multiWordIsSearch() {
        let resolved = URLInput.resolve("swift concurrency guide")
        #expect(resolved?.absoluteString.hasPrefix(URLInput.searchTemplate) == true)
        #expect(resolved?.absoluteString.contains("swift%20concurrency%20guide") == true)
    }

    @Test("A single word with no dot is a search, not a DNS error")
    func singleWordIsSearch() {
        let resolved = URLInput.resolve("swift")
        #expect(resolved?.absoluteString.hasPrefix(URLInput.searchTemplate) == true)
    }

    @Test("A trailing numeric segment is a search, not a host")
    func numericTLDIsSearch() {
        let resolved = URLInput.resolve("version.2")
        #expect(resolved?.absoluteString.hasPrefix(URLInput.searchTemplate) == true)
    }

    @Test("Empty and whitespace input resolve to nothing")
    func emptyIsNil() {
        #expect(URLInput.resolve("") == nil)
        #expect(URLInput.resolve("   \n ") == nil)
    }

    @Test("Surrounding whitespace is trimmed")
    func trimsWhitespace() {
        #expect(URLInput.resolve("  example.com  ")?.absoluteString == "https://example.com")
    }
}
