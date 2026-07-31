import BrowserCore
import BrowserStore
import BrowserTestSupport
import Foundation
import Testing

/// What we actually put on the wire (9.6).
///
/// Sites sniff the User-Agent, and Google in particular serves a stripped-down
/// page to anything it does not recognise. This is the only place that can
/// catch it: no unit test sees a real HTTP request, and by the time it shows up
/// it looks like a rendering bug rather than a header.
@Suite("E2E: user agent", .serialized)
@MainActor
struct UserAgentE2ETests {

    @Test("The request carries a Safari-shaped User-Agent")
    func sendsASafariUserAgent() async throws {
        let harness = try await E2EHarness.make(
            routes: [.page(path: "/", title: "Home Page", body: "<h1>Home</h1>")]
        )
        defer { Task { await harness.tearDown() } }

        await harness.store.restore()
        _ = await harness.openAndLoad(await harness.server.url(""))

        // The document request specifically. The favicon that follows it comes
        // from URLSession and carries CFNetwork's User-Agent, so "the last
        // request" answers about the wrong one.
        let agent = try #require(await harness.server.header("user-agent", forPath: "/"))

        // WebKit always sends these.
        #expect(agent.contains("Mozilla/5.0"))
        #expect(agent.contains("AppleWebKit"))

        // These two come from `applicationNameForUserAgent`, and are absent
        // when it is not set. Without them the UA has no browser token at all,
        // and Google serves its no-frills page — which is exactly how this was
        // found, from a screenshot that looked wrong rather than a failure.
        #expect(agent.contains("Version/"), "no Version token: \(agent)")
        #expect(agent.contains("Safari/"), "no Safari token: \(agent)")
    }

    @Test("A per-domain rule is what actually goes on the wire")
    func perDomainOverrideReachesTheServer() async throws {
        let harness = try await E2EHarness.make(
            routes: [.page(path: "/", title: "Home Page", body: "<h1>Home</h1>")]
        )
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()

        // The rule names the loopback host the test server runs on. Everything
        // else here is the ordinary path: no test hooks, no injection.
        #expect(harness.store.setUserAgentOverride(domain: "127.0.0.1", preference: .chrome))

        _ = await harness.openAndLoad(await harness.server.url(""))

        let agent = try #require(await harness.server.header("user-agent", forPath: "/"))
        // The decisive assertion: the header, not the property. The unit tests
        // prove the matching rules; only this proves the resolved UA survives
        // the trip through the navigation policy and onto the request.
        #expect(agent.contains("Chrome/"), "per-domain rule did not reach the wire: \(agent)")
    }
}
