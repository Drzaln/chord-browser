import ChordCore
import ChordStore
import ChordTestSupport
import Foundation
import Testing

/// Per-site cookie inspection against real WebKit (non-spec: user-requested).
///
/// `WKHTTPCookieStore.cookies(for:)` is macOS 27, so the test is a no-op on an
/// older runtime — the API it exercises does not exist there.
@Suite("E2E: site cookies", .serialized)
@MainActor
struct CookieE2ETests {

    @Test("A site's cookie is listed, then cleared")
    func listsAndClears() async throws {
        guard #available(macOS 27.0, *) else { return }

        let harness = try await E2EHarness.make(
            routes: [.cookieSetter(path: "/set", title: "Set", cookie: "session=abc")]
        )
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()

        #expect(await harness.openAndLoad(await harness.server.url("/set")))
        // Let the cookie land in the store before asking for it.
        try? await Task.sleep(for: .milliseconds(300))

        let spaceID = try #require(harness.store.spaces.first?.id)
        let url = await harness.server.url("/set")

        let cookies = await harness.store.siteCookies(for: url, inSpace: spaceID)
        #expect(cookies.contains { $0.name == "session" && $0.value == "abc" })

        await harness.store.clearSiteCookies(for: url, inSpace: spaceID)
        let after = await harness.store.siteCookies(for: url, inSpace: spaceID)
        #expect(after.isEmpty, "clearing the site must leave no cookies there")
    }
}
