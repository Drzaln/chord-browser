import Foundation
import Testing

@testable import ChordCore

@Suite("Site overrides")
struct SiteOverrideTests {

    @Test("Zapped selectors become hide rules ahead of the user's CSS")
    func stylesheetHidesThenAppliesCSS() {
        let override = SiteOverride(
            pattern: "example.com",
            css: "body { font-family: system-ui; }",
            hiddenSelectors: [".sidebar", "#promo"]
        )
        let sheet = SiteOverrides.stylesheet(for: override)
        #expect(sheet.contains(".sidebar { display: none !important; }"))
        #expect(sheet.contains("#promo { display: none !important; }"))
        #expect(sheet.contains("body { font-family: system-ui; }"))
        #expect(sheet.hasPrefix(".sidebar"))
    }

    @Test("A selector that could break out of its block is skipped")
    func rejectsMalformedSelectors() {
        let override = SiteOverride(
            pattern: "example.com",
            css: "p { color: red; }",
            hiddenSelectors: [".ok", "a { color: blue }", "", ";"]
        )
        let sheet = SiteOverrides.stylesheet(for: override)
        #expect(sheet.contains(".ok { display: none !important; }"))
        #expect(!sheet.contains("color: blue"))
        #expect(SiteOverrides.isUsableSelector("div > span"))
        #expect(!SiteOverrides.isUsableSelector("div { }"))
    }

    @Test("An empty override is not worth injecting")
    func hasContentRequiresSomething() {
        #expect(!SiteOverride(pattern: "example.com").hasContent)
        #expect(!SiteOverride(pattern: "example.com", css: "  \n").hasContent)
        #expect(SiteOverride(pattern: "example.com", hiddenSelectors: [".ad"]).hasContent)
        #expect(SiteOverride(pattern: "example.com", js: "console.log(1)").hasContent)
    }

    @Test("Matching covers subdomains, prefers the most specific, ignores disabled")
    func matchesByHost() {
        var disabled = SiteOverride(pattern: "docs.example.com", css: "p{}")
        disabled.isEnabled = false
        let overrides = [SiteOverride(pattern: "example.com", css: "p{}"), disabled]
        #expect(SiteOverrides.match(host: "www.example.com", in: overrides)?.pattern == "example.com")
        #expect(SiteOverrides.match(host: "docs.example.com", in: overrides)?.pattern == "example.com")
        #expect(SiteOverrides.match(host: "example.com.evil.test", in: overrides) == nil)
    }
}
