import Foundation
import Testing

@testable import ChordCore

@Suite("Routing rules")
struct RouteRuleTests {

    private let work = UUID()
    private let design = UUID()

    @Test("A rule normalises a pasted URL, a bare host, and a leading dot")
    func normalisesInput() {
        #expect(RouteRules.normalise("https://www.figma.com/file/abc") == "www.figma.com")
        #expect(RouteRules.normalise("  Figma.com ") == "figma.com")
        #expect(RouteRules.normalise(".figma.com") == "figma.com")
        #expect(RouteRules.normalise("chrome") == nil)
        #expect(RouteRules.normalise("") == nil)
    }

    @Test("A rule covers its subdomains but not a lookalike")
    func matchesSubdomainsOnly() {
        let rules = [RouteRule(pattern: "figma.com", spaceID: design)]
        #expect(RouteRules.match(host: "figma.com", in: rules)?.spaceID == design)
        #expect(RouteRules.match(host: "app.figma.com", in: rules)?.spaceID == design)
        #expect(RouteRules.match(host: "notfigma.com", in: rules) == nil)
        #expect(RouteRules.match(host: "evil-figma.com", in: rules) == nil)
    }

    @Test("The most specific rule wins, and a disabled rule is ignored")
    func mostSpecificWins() {
        var disabled = RouteRule(pattern: "docs.figma.com", spaceID: work)
        disabled.isEnabled = false
        let rules = [RouteRule(pattern: "figma.com", spaceID: design), disabled]
        #expect(RouteRules.match(host: "docs.figma.com", in: rules)?.spaceID == design)

        var enabled = disabled
        enabled.isEnabled = true
        #expect(
            RouteRules.match(
                host: "docs.figma.com", in: [RouteRule(pattern: "figma.com", spaceID: design), enabled]
            )?.spaceID == work
        )
    }

    @Test("External launches always route; new tabs only when the rule says so")
    func kindControlsNewTabs() {
        let rules = [RouteRule(pattern: "figma.com", spaceID: design, routesNewTabs: false)]
        let url = URL(string: "https://www.figma.com/file/1")!
        #expect(
            RouteRules.destination(
                for: url, kind: .external, rules: rules, knownSpaceIDs: [design]
            ) == design
        )
        #expect(
            RouteRules.destination(
                for: url, kind: .newTab, rules: rules, knownSpaceIDs: [design]
            ) == nil
        )
    }

    @Test("A rule pointing at a Space that no longer exists is inert")
    func deletedSpaceIsInert() {
        let rules = [RouteRule(pattern: "figma.com", spaceID: design)]
        let url = URL(string: "https://figma.com/")!
        #expect(
            RouteRules.destination(
                for: url, kind: .external, rules: rules, knownSpaceIDs: [work]
            ) == nil
        )
    }
}
