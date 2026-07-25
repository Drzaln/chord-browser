import Foundation
import Testing

@testable import BrowserCore

@Suite("Content-block converter (C1)")
struct ContentBlockConverterTests {
    // MARK: - url-filter translation

    @Test("A domain anchor becomes a scheme + optional-subdomain regex")
    func domainAnchor() {
        #expect(
            ContentBlockConverter.urlFilter(from: "||example.com^")
                == #"^https?://([^/]*\.)?example\.com[^a-zA-Z0-9_.%-]"#
        )
    }

    @Test("Wildcards and separators translate; regex metacharacters are escaped")
    func wildcardsAndEscaping() {
        #expect(ContentBlockConverter.urlFilter(from: "/ads/*") == "/ads/.*")
        // The dot is escaped, the star becomes .*
        #expect(ContentBlockConverter.urlFilter(from: "a.b*c") == #"a\.b.*c"#)
    }

    @Test("Start and end anchors map to ^ and $")
    func anchors() {
        #expect(ContentBlockConverter.urlFilter(from: "|http://x") == "^http://x")
        #expect(ContentBlockConverter.urlFilter(from: "swf|") == "swf$")
    }

    // MARK: - Network rules

    @Test("A plain domain rule blocks")
    func simpleBlock() {
        let rule = ContentBlockConverter.convertLine("||ads.example.com^")
        #expect(rule?.action.type == .block)
        #expect(rule?.trigger.urlFilter.contains("ads") == true)
    }

    @Test("An @@ rule becomes ignore-previous-rules")
    func exception() {
        let rule = ContentBlockConverter.convertLine("@@||example.com^")
        #expect(rule?.action.type == .ignorePreviousRules)
    }

    @Test("third-party and domain options map to load-type and if/unless-domain")
    func optionsMapping() {
        let rule = ContentBlockConverter.convertLine("||track.com^$third-party,domain=a.com|~b.com")
        #expect(rule?.trigger.loadType == ["third-party"])
        #expect(rule?.trigger.ifDomain == ["*a.com"])
        #expect(rule?.trigger.unlessDomain == ["*b.com"])
    }

    @Test("Resource-type options map onto Apple's names")
    func resourceTypes() {
        let rule = ContentBlockConverter.convertLine("||cdn.com/a^$script,stylesheet,xmlhttprequest")
        #expect(rule?.trigger.resourceType == ["script", "style-sheet", "raw"])
    }

    @Test("~third-party is first-party")
    func firstParty() {
        #expect(
            ContentBlockConverter.convertLine("||x.com^$~third-party")?.trigger.loadType
                == ["first-party"]
        )
    }

    // MARK: - Element hiding

    @Test("A generic element-hiding rule hides on all sites")
    func genericHide() {
        let rule = ContentBlockConverter.convertLine("##.ad-banner")
        #expect(rule?.action.type == .cssDisplayNone)
        #expect(rule?.action.selector == ".ad-banner")
        #expect(rule?.trigger.urlFilter == ".*")
        #expect(rule?.trigger.ifDomain == nil)
    }

    @Test("A domain-scoped element-hiding rule sets if-domain")
    func scopedHide() {
        let rule = ContentBlockConverter.convertLine("example.com,~sub.example.com###promo")
        #expect(rule?.action.selector == "#promo")
        #expect(rule?.trigger.ifDomain == ["*example.com"])
        #expect(rule?.trigger.unlessDomain == ["*sub.example.com"])
    }

    @Test("A standard :has() element-hiding rule is kept (WebKit compiles it)")
    func hasSelectorKept() {
        let rule = ContentBlockConverter.convertLine("example.com##div.wrap:has(> a.ad)")
        #expect(rule?.action.type == .cssDisplayNone)
        #expect(rule?.action.selector == "div.wrap:has(> a.ad)")
        #expect(rule?.trigger.ifDomain == ["*example.com"])
    }

    @Test(
        "A ## rule using a proprietary procedural pseudo is dropped",
        arguments: [
            "##div:has(.ad):upward(2)",  // :has mixed with procedural :upward
            "##.item:-abp-has(.sponsored)",
            "##.box:has-text(Sponsored)",
            "##div:xpath(//ad)",
            "##.c:matches-css-before(content: ad)",
        ]
    )
    func proceduralCosmeticDropped(line: String) {
        #expect(ContentBlockConverter.convertLine(line) == nil)
    }

    // MARK: - Dropped rules

    @Test(
        "Unsupported filters are dropped, not mis-converted",
        arguments: [
            "/banner\\d+/",  // regex literal
            "example.com#@#.ad",  // cosmetic exception
            "example.com#?#.ad:has(> img)",  // extended CSS
            "abp-scriptlet#%#//scriptlet('x')",  // scriptlet
            "||x.com^$redirect=noop.js",  // unmapped modifier
            "||x.com^$~script",  // negated resource type
        ]
    )
    func droppedRules(line: String) {
        #expect(ContentBlockConverter.convertLine(line) == nil)
    }

    @Test("Comments, headers, and blanks are not counted as skipped")
    func commentsAreNotSkips() {
        let list = """
            [Adblock Plus 2.0]
            ! a comment

            ||ads.com^
            /bad regex/
            """
        let result = ContentBlockConverter.convert(list)
        // Two real filters seen: the block and the (dropped) regex literal.
        #expect(result.parsedLines == 2)
        #expect(result.rules.count == 1)
        #expect(result.skipped == 1)
    }

    // MARK: - JSON shape

    @Test("Rules serialise to Apple's hyphenated content-blocker JSON")
    func jsonShape() throws {
        let rules = ContentBlockConverter.convert("||ads.com^$third-party").rules
        let json = try rules.contentRuleListJSON()
        #expect(json.contains("\"url-filter\""))
        #expect(json.contains("\"load-type\":[\"third-party\"]"))
        #expect(json.contains("\"type\":\"block\""))
        // Slashes are not escaped, so the regex reads cleanly.
        #expect(!json.contains("\\/"))
    }

    @Test("A whole small list converts and round-trips to valid JSON")
    func endToEnd() throws {
        let list = """
            ! EasyList sample
            ||doubleclick.net^
            ||googlesyndication.com^$third-party
            @@||example.com/allowed^
            ##.sponsored
            reddit.com###ad-slot
            """
        let result = ContentBlockConverter.convert(list)
        #expect(result.rules.count == 5)
        #expect(result.skipped == 0)
        // Valid JSON: it parses back to an array of 5 objects.
        let data = try result.rules.contentRuleListJSON().data(using: .utf8)!
        let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        #expect(parsed?.count == 5)
    }
}
