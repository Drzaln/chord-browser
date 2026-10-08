import ChordStore
import ChordTestSupport
import Foundation
import Testing
import WebKit

@testable import ChordEngine

/// End-to-end: the offline easter-egg page is actually served by the private
/// scheme handler through a real `WKWebView`, and a reload retries the page the
/// game stands in for.
@Suite("E2E: offline game", .serialized)
@MainActor
struct OfflineGameE2ETests {

    @Test("The offline page is served and titled")
    func servesOfflinePage() async throws {
        let harness = try await E2EHarness.make(routes: [])
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()

        let target = URL(string: "https://example.com/thing")!
        harness.store.newTab(url: OfflineGamePage.url(target: target))
        guard let tab = harness.store.selectedTab else {
            Issue.record("no tab opened")
            return
        }
        _ = harness.store.surface(for: tab)

        let paneID = tab.focusedPaneID
        let loaded = await harness.wait {
            harness.store.runtime(for: paneID).currentURL?.scheme == OfflineGamePage.scheme
        }
        #expect(loaded)

        let titled = await harness.wait {
            harness.store.selectedTab?.displayTitle == "No Internet"
        }
        #expect(titled)
    }

    @Test("The game script initializes and starts in the page")
    func scriptRuns() async throws {
        let harness = try await E2EHarness.make(routes: [])
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()

        harness.store.newTab(url: OfflineGamePage.url(target: nil))
        guard let tab = harness.store.selectedTab else {
            Issue.record("no tab opened")
            return
        }
        _ = harness.store.surface(for: tab)
        let paneID = tab.focusedPaneID
        _ = await harness.wait {
            harness.store.runtime(for: paneID).currentURL?.scheme == OfflineGamePage.scheme
                && harness.store.selectedTab?.displayTitle == "No Internet"
        }
        let view = try #require(harness.engine.pool.peek(paneID)?.webView)

        let hook = try await view.evaluateJavaScript("typeof window.__chordOffline")
        #expect(hook as? String == "object")

        let phase = try await view.evaluateJavaScript(
            "window.__chordOffline.start();"
                + "for (var i = 0; i < 30; i++) window.__chordOffline.step(1);"
                + "window.__chordOffline.state().phase"
        )
        #expect(phase as? String == "running")
    }

    @Test("A reload retries the failed page, not the game")
    func reloadRetriesTarget() async throws {
        let routes: [TestHTTPServer.Route] = [
            .page(path: "/home", title: "Home Page")
        ]
        let harness = try await E2EHarness.make(routes: routes)
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()

        let pageURL = await harness.server.url("home")
        #expect(await harness.openAndLoad(pageURL))
        guard let paneID = harness.store.selectedTab?.focusedPaneID else {
            Issue.record("no focused pane")
            return
        }

        harness.engine.presentOfflineGame(for: paneID, failedURL: pageURL)
        let showedGame = await harness.wait {
            harness.store.runtime(for: paneID).currentURL?.scheme == OfflineGamePage.scheme
        }
        #expect(showedGame)

        harness.engine.reload(paneID: paneID)
        let retried = await harness.wait {
            harness.store.runtime(for: paneID).currentURL == pageURL
                && !harness.store.runtime(for: paneID).isLoading
        }
        #expect(retried)
    }
}
