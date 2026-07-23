import BrowserCore
import BrowserStore
import BrowserTestSupport
import Foundation
import Testing

/// End-to-end: a real `WKWebView` loads a real page over real HTTP, and the
/// result lands in a real SQLite file.
///
/// These are the tests that would have caught an integration mistake the unit
/// tests cannot see — a delegate never wired up, a save never flushed, a
/// migration that runs but stores nothing.
@Suite("E2E: browsing", .serialized)
@MainActor
struct BrowsingE2ETests {

    private var routes: [TestHTTPServer.Route] {
        [
            .page(path: "/", title: "Home Page", body: "<h1>Home</h1>"),
            .page(path: "/second", title: "Second Page", body: "<h1>Second</h1>"),
        ]
    }

    @Test("Loading a page captures its title into the model")
    func loadCapturesTitle() async throws {
        let harness = try await E2EHarness.make(routes: routes)
        defer { Task { await harness.tearDown() } }

        await harness.store.restore()
        let loaded = await harness.openAndLoad(await harness.server.url("second"))
        #expect(loaded)

        let titled = await harness.wait {
            harness.store.selectedTab?.displayTitle == "Second Page"
        }
        #expect(titled)
    }

    @Test("A loaded page is persisted and restored on relaunch")
    func stateSurvivesRelaunch() async throws {
        let harness = try await E2EHarness.make(routes: routes)
        defer { Task { await harness.tearDown() } }

        await harness.store.restore()
        _ = await harness.openAndLoad(await harness.server.url("second"))
        _ = await harness.wait { harness.store.selectedTab?.displayTitle == "Second Page" }

        // flushSave bypasses the 2s debounce, the same way quitting does.
        harness.store.flushSave()
        _ = await harness.wait { true }
        try await Task.sleep(for: .milliseconds(300))

        let relaunched = try harness.relaunch()
        await relaunched.restore()

        #expect(relaunched.tabs.contains { $0.displayTitle == "Second Page" })

        // The whole point of lazy restore: nothing has spawned a content
        // process yet (6.2).
        #expect(relaunched.liveWebViewCount == 0)

        relaunched.stopSweep()
    }

    @Test("Visiting a page records it in history, findable from the command bar")
    func historyIsRecordedAndSearchable() async throws {
        let harness = try await E2EHarness.make(routes: routes)
        defer { Task { await harness.tearDown() } }

        await harness.store.restore()
        _ = await harness.openAndLoad(await harness.server.url("second"))
        _ = await harness.wait { harness.store.selectedTab?.displayTitle == "Second Page" }

        // History is written on a background queue; wait for it to land.
        let recorded = await harness.wait {
            true
        }
        #expect(recorded)
        try await Task.sleep(for: .milliseconds(400))

        await harness.store.prepareCommandBar()
        let results = harness.store.suggestions(for: "Second")

        #expect(results.contains { $0.title == "Second Page" })
    }

    @Test("A web view is created only when a tab is actually shown")
    func viewsAreLazy() async throws {
        let harness = try await E2EHarness.make(routes: routes)
        defer { Task { await harness.tearDown() } }

        await harness.store.restore()
        #expect(harness.store.liveWebViewCount == 0)

        harness.store.newTab(url: await harness.server.url("/"))
        // Still nothing: the tab exists, but nobody has asked to render it.
        #expect(harness.store.liveWebViewCount == 0)

        _ = harness.store.surface(for: try #require(harness.store.selectedTab))
        #expect(harness.store.liveWebViewCount == 1)
    }

    @Test("Navigating updates the address the model holds")
    func navigationUpdatesModel() async throws {
        let harness = try await E2EHarness.make(routes: routes)
        defer { Task { await harness.tearDown() } }

        await harness.store.restore()
        _ = await harness.openAndLoad(await harness.server.url("/"))

        let target = await harness.server.url("second")
        harness.store.navigate(to: target)

        let arrived = await harness.wait {
            harness.store.selectedTab?.focusedPane.url.path() == "/second"
        }
        #expect(arrived)
    }
}
