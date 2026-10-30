import Foundation
import Testing

@testable import ChordEngine

/// Which site may send a tab to an extension's page: only a file the
/// manifest exposes to it, and nothing read more permissively than written.
struct ExtensionPageAccessTests {
    private let manifest: [String: Any] = [
        "manifest_version": 3,
        "web_accessible_resources": [
            ["resources": ["blocked.html", "pages/*"], "matches": ["https://*.example.com/*"]],
        ],
    ]
    private let base = "chrome-extension://abcdefghijklmnopabcdefghijklmnop"

    private func allows(_ path: String, from source: String) -> Bool {
        ExtensionPageAccess.allows(
            target: URL(string: base + path)!, source: URL(string: source)!, manifest: manifest
        )
    }

    @Test func anExposedFileOpensFromAMatchingSite() {
        #expect(allows("/blocked.html", from: "https://news.example.com/a"))
        #expect(allows("/pages/one.html", from: "https://example.com/"))
        #expect(!allows("/pages/one.html", from: "http://example.com/"), "the rule names https")
    }

    @Test func otherSitesAndFilesAreRefused() {
        #expect(!allows("/blocked.html", from: "https://example.org/"))
        #expect(!allows("/options.html", from: "https://news.example.com/"))
        #expect(!allows("/blocked.html", from: "file:///tmp/x.html"))
    }

    @Test func trickyPathsFailClosed() {
        #expect(!allows("/pages/../options.html", from: "https://example.com/"))
        #expect(!allows("/pages%2Fone.html", from: "https://example.com/"))
        #expect(!allows("//blocked.html", from: "https://example.com/"))
    }

    @Test func aRuleTargetGetsItsFragmentAndQueryBack() {
        let fragment = ExtensionPageAccess.ruleTarget(URL(string: base + "/blocked.html%23site")!)
        #expect(fragment.path == "/blocked.html")
        #expect(fragment.fragment == "site")
        let both = ExtensionPageAccess.ruleTarget(URL(string: base + "/b.html%3Fu=1%23top")!)
        #expect(both.query == "u=1")
        #expect(both.fragment == "top")
        let plain = URL(string: base + "/b.html?u=1")!
        #expect(ExtensionPageAccess.ruleTarget(plain) == plain)
    }
}
