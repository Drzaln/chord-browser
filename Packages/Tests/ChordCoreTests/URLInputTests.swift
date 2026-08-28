import ChordCore
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
        #expect(URLInput.isSearch("swift concurrency guide"))
        #expect(resolved?.absoluteString.contains("swift%20concurrency%20guide") == true)
    }

    @Test("A single word with no dot is a search, not a DNS error")
    func singleWordIsSearch() {
        #expect(URLInput.isSearch("swift"))
    }

    @Test("A trailing numeric segment is a search, not a host")
    func numericTLDIsSearch() {
        #expect(URLInput.isSearch("version.2"))
    }

    @Test("A custom template substitutes the encoded query into %s")
    func customTemplateSubstitutes() {
        let template = "https://example.com/find?query=%s&lang=en"
        let resolved = URLInput.resolve("hello world", searchTemplate: template)
        #expect(
            resolved?.absoluteString == "https://example.com/find?query=hello%20world&lang=en"
        )
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

    @Test("A leading '?' forces a search query", arguments: [
        ("?golang.org", "golang.org"),
        ("? golang.org", "golang.org"),
        (" ?x ", "x"),
        ("??", "?"),
        ("?  ", nil),
        ("?", nil),
        ("example.com", nil),
        ("https://x", nil),
    ])
    func forcedSearchQuery(input: String, expected: String?) {
        #expect(URLInput.forcedSearchQuery(input) == expected)
    }

    @Test("A leading '@' splits into alias and query", arguments: [
        ("@gh swift", "gh", "swift"),
        ("@so stack overflow", "so", "stack overflow"),
        (" @gh  swift ", "gh", "swift"),
        ("@gh swift x", "gh", "swift x"),
    ])
    func siteSearchQuery(input: String, alias: String, query: String) {
        let parsed = URLInput.siteSearchQuery(input)
        #expect(parsed?.alias == alias)
        #expect(parsed?.query == query)
    }

    @Test("An '@' with no alias or no query does not parse", arguments: [
        "@", "@gh", "@gh  ",
    ])
    func siteSearchQueryFallsThrough(input: String) {
        #expect(URLInput.siteSearchQuery(input) == nil)
    }

    /// The URL-vs-search corpus (QoL #4): each input -> whether it is treated
    /// as a *search* (true) or a *navigation* (false). Captured from the rules
    /// in `looksLikeHost`, covering TLD gibberish, a "www." prefix, intranet
    /// words, and the common cases that must not regress.
    @Test("URL-vs-search corpus", arguments: [
        ("example.com", false),                    // common host still navigates
        ("www.example.com", false),                // www prefix keeps its TLD
        ("news.ycombinator.com/newest", false),    // path after the host
        ("mysite.io", false),                      // generic TLD navigates
        ("localhost", false),                      // sole single-word navigator
        ("foo.grok", true),                        // TLD gibberish -> search
        ("www.grok", true),                        // www + gibberish -> search
        ("nas", true),                             // intranet word -> search
        ("myserver", true),                        // intranet word -> search
        ("version.2", true),                       // numeric TLD -> search
        ("swift concurrency", true),               // multi-word -> search
    ])
    func urlVsSearchCorpus(input: String, expectedIsSearch: Bool) {
        #expect(URLInput.isSearch(input) == expectedIsSearch)
    }
}
