import Foundation
import Testing

@testable import ChordCore

/// The referrer rule set (non-spec: user-requested). Pure, so every branch of
/// the matching is tested here — a loose suffix match would leak the page you
/// came from to the wrong site, the same class of mistake as a loose origin
/// match in the vault.
@Suite("Referrer rules")
struct ReferrerRulesTests {

    @Test("Normalising accepts a URL, a bare host, or a leading dot")
    func normaliseAcceptsRealInput() {
        #expect(ReferrerRules.normalise("https://MEET.google.com/abc?x=1") == "meet.google.com")
        #expect(ReferrerRules.normalise("example.com") == "example.com")
        #expect(ReferrerRules.normalise(".google.com") == "google.com")
    }

    @Test("Normalising refuses what is not a host")
    func normaliseRefusesJunk() {
        #expect(ReferrerRules.normalise("strip") == nil)
        #expect(ReferrerRules.normalise("") == nil)
        #expect(ReferrerRules.normalise("two words.com") == nil)
    }

    @Test("A rule covers its subdomains, and the most specific rule wins")
    func matchCoversSubdomains() {
        let rules = [
            ReferrerOverride(domain: "google.com", policy: .strip),
            ReferrerOverride(domain: "meet.google.com", policy: .default),
        ]
        #expect(ReferrerRules.match(host: "meet.google.com", in: rules)?.policy == .default)
        #expect(ReferrerRules.match(host: "mail.google.com", in: rules)?.policy == .strip)
    }

    @Test("A suffix match never crosses a dot boundary")
    func matchIsDotAnchored() {
        let rules = [ReferrerOverride(domain: "google.com", policy: .strip)]
        #expect(ReferrerRules.match(host: "evil-google.com", in: rules) == nil)
        #expect(ReferrerRules.match(host: "notgoogle.com", in: rules) == nil)
    }

    @Test("Resolve: global default leaves WebKit's referrer alone")
    func resolveGlobalDefault() {
        #expect(ReferrerRules.resolve(url: URL(string: "https://a.com/"), overrides: [], global: .default) == nil)
    }

    @Test("Resolve: global strip sends nothing, custom sends the URL")
    func resolveGlobalStripAndCustom() {
        #expect(ReferrerRules.resolve(url: URL(string: "https://a.com/"), overrides: [], global: .strip) == "")
        #expect(
            ReferrerRules.resolve(
                url: URL(string: "https://a.com/"), overrides: [], global: .custom("https://ref.example/")
            ) == "https://ref.example/"
        )
    }

    @Test("A per-domain rule beats the global policy, including a carve-out")
    func resolvePerDomainBeatsGlobal() {
        let overrides = [ReferrerOverride(domain: "bank.com", policy: .default)]
        // Globally stripped, but this one site keeps its own referrer.
        #expect(
            ReferrerRules.resolve(url: URL(string: "https://bank.com/login"), overrides: overrides, global: .strip)
                == nil
        )
        #expect(
            ReferrerRules.resolve(url: URL(string: "https://other.com/"), overrides: overrides, global: .strip) == ""
        )
    }
}
