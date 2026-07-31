import Foundation
import Testing

@testable import BrowserCore

/// Per-domain User-Agent rules (§9.6).
///
/// The near-miss table is the point, for the same reason the vault's origin
/// matcher has one: a loose suffix match silently hands a spoofed identity to a
/// site that merely *looks* like the one the rule named.
@Suite("User-Agent rules")
struct UserAgentRulesTests {

    private let chrome = UserAgentPreference.chrome
    private let firefox = UserAgentPreference.firefox

    // MARK: - Normalising what the user typed

    @Test("A pasted URL becomes a domain")
    func normalisesURLs() {
        #expect(UserAgentRules.normalise("https://meet.google.com/abc-def") == "meet.google.com")
        #expect(UserAgentRules.normalise("  HTTPS://Example.COM/  ") == "example.com")
        #expect(UserAgentRules.normalise(".google.com.") == "google.com")
        #expect(UserAgentRules.normalise("example.com:8443") == "example.com")
        #expect(UserAgentRules.normalise("user@example.com") == "example.com")
        #expect(UserAgentRules.normalise("example.com?q=1") == "example.com")
    }

    @Test("Something that is not a domain is refused rather than stored")
    func refusesNonDomains() {
        // Otherwise "chrome" becomes a rule that silently matches nothing, and
        // the user is left believing the site is covered.
        #expect(UserAgentRules.normalise("chrome") == nil)
        #expect(UserAgentRules.normalise("") == nil)
        #expect(UserAgentRules.normalise("   ") == nil)
        #expect(UserAgentRules.normalise("two words.com") == nil)
    }

    // MARK: - Matching

    @Test("A rule covers the domain and its subdomains")
    func matchesSubdomains() {
        let rules = [UserAgentOverride(domain: "google.com", preference: chrome)]
        #expect(UserAgentRules.match(host: "google.com", in: rules)?.domain == "google.com")
        #expect(UserAgentRules.match(host: "meet.google.com", in: rules)?.domain == "google.com")
        #expect(UserAgentRules.match(host: "a.b.google.com", in: rules)?.domain == "google.com")
        #expect(UserAgentRules.match(host: "GOOGLE.COM", in: rules)?.domain == "google.com")
    }

    @Test("Near-misses never match")
    func rejectsNearMisses() {
        let rules = [UserAgentOverride(domain: "google.com", preference: chrome)]
        // The suffix must be preceded by a dot. Each of these is a different
        // site, and a plain `hasSuffix` would hand three of them the rule.
        for host in [
            "evil-google.com", "notgoogle.com", "google.com.evil.com",
            "google.co", "xgoogle.com", "com",
        ] {
            #expect(UserAgentRules.match(host: host, in: rules) == nil, "\(host) must not match")
        }
    }

    @Test("The most specific rule wins")
    func longestMatchWins() {
        let rules = [
            UserAgentOverride(domain: "google.com", preference: chrome),
            UserAgentOverride(domain: "meet.google.com", preference: .default),
        ]
        #expect(UserAgentRules.match(host: "meet.google.com", in: rules)?.domain == "meet.google.com")
        #expect(UserAgentRules.match(host: "mail.google.com", in: rules)?.domain == "google.com")
    }

    // MARK: - Resolving

    @Test("A rule beats the global setting")
    func overrideBeatsGlobal() {
        let rules = [UserAgentOverride(domain: "example.com", preference: chrome)]
        let resolved = UserAgentRules.resolve(
            url: URL(string: "https://example.com/x"), overrides: rules, global: firefox
        )
        #expect(resolved == chrome.resolvedUserAgent)
    }

    @Test("A site with no rule keeps the global setting")
    func fallsBackToGlobal() {
        let rules = [UserAgentOverride(domain: "example.com", preference: chrome)]
        let resolved = UserAgentRules.resolve(
            url: URL(string: "https://other.example/x"), overrides: rules, global: firefox
        )
        #expect(resolved == firefox.resolvedUserAgent)
    }

    @Test("A per-domain Default turns a global spoof off for that site")
    func perDomainDefaultDisablesTheGlobalSpoof() {
        // The reason this feature exists: Google Meet refuses to start a call
        // under the Firefox UA, and until now the only fix was to give up the
        // global setting entirely.
        let rules = [UserAgentOverride(domain: "meet.google.com", preference: .default)]
        let meet = UserAgentRules.resolve(
            url: URL(string: "https://meet.google.com/abc"), overrides: rules, global: firefox
        )
        let elsewhere = UserAgentRules.resolve(
            url: URL(string: "https://example.com"), overrides: rules, global: firefox
        )
        #expect(meet == nil, "nil means the browser's own completed Safari UA")
        #expect(elsewhere == firefox.resolvedUserAgent)
    }

    @Test("A URL with no host falls back to the global setting")
    func hostlessURL() {
        let resolved = UserAgentRules.resolve(
            url: URL(string: "about:blank"), overrides: [], global: firefox
        )
        #expect(resolved == firefox.resolvedUserAgent)
    }
}
