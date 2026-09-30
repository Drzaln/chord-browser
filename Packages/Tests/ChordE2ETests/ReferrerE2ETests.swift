import ChordCore
import ChordStore
import ChordTestSupport
import Foundation
import Testing

/// The referrer policy, against real WebKit (non-spec: user-requested).
///
/// `WKWebpagePreferences.overrideReferrer` is macOS 27, so each test is a no-op
/// on an older runtime — there is no referrer control to exercise there.
@Suite("E2E: referrer policy", .serialized)
@MainActor
struct ReferrerE2ETests {

    /// A page whose only subresource is an image, so the server sees a
    /// subresource request that must carry the frame's referrer override.
    private static func pageWithSubresource() -> TestHTTPServer.Route {
        .page(path: "/", title: "Referrer", body: "<img src=\"/img\">")
    }

    @Test("A global strip sends no referrer on the subresource")
    func stripRemovesReferrer() async throws {
        guard #available(macOS 27.0, *) else { return }

        let harness = try await E2EHarness.make(
            routes: [Self.pageWithSubresource(), .page(path: "/img", title: "img")]
        )
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()

        harness.store.referrerPolicy = .strip
        #expect(await harness.openAndLoad(await harness.server.url("/")))
        try? await Task.sleep(for: .milliseconds(400))

        // The image is a subresource of the main frame; the override must reach it.
        #expect(await harness.server.header("referer", forPath: "/img") == "")
    }

    @Test("A per-domain custom referrer is sent")
    func customReferrer() async throws {
        guard #available(macOS 27.0, *) else { return }

        let harness = try await E2EHarness.make(
            routes: [Self.pageWithSubresource(), .page(path: "/img", title: "img")]
        )
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()

        // The test server is on 127.0.0.1 — a rule for it applies to the page.
        #expect(
            harness.store.setReferrerOverride(
                domain: "127.0.0.1", policy: .custom("https://ref.example/")
            )
        )
        #expect(await harness.openAndLoad(await harness.server.url("/")))
        try? await Task.sleep(for: .milliseconds(400))

        #expect(await harness.server.header("referer", forPath: "/img") == "https://ref.example/")
    }
}
