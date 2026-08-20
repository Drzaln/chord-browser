import ChordCore
import ChordEngine
import ChordStore
import ChordTestSupport
import Foundation
import Testing
import WebKit

@testable import ChordEngine
@testable import ChordStore

/// End-to-end for the `window.open()` / `target="_blank"` popup path.
///
/// The bug this guards: a popup opened as a *plain* store tab gives the page's
/// `window.open()` call `null`, so OAuth login (Shopee's Google button, etc.)
/// has no window reference to poll or read the result from, and `window.close()`
/// is ignored on a normal tab, so the popup lingers forever. A real popup web
/// view keeps the `window.open()` reference live and lets the page close itself.
@Suite("E2E: window.open popups", .serialized)
@MainActor
struct PopupE2ETests {

    private var routes: [TestHTTPServer.Route] {
        [
            .page(
                path: "/opener",
                title: "Opener Page",
                body: """
                <h1>Opener</h1>
                <a id="go" href="#" onclick="window.myWin = window.open('/popup', 'p', 'width=500,height=600'); return false;">go</a>
                """
            ),
            .page(path: "/popup", title: "Popup Page", body: "<h1>Popup</h1>"),
        ]
    }

    @Test("A window.open popup keeps its window reference and closes itself")
    func popupKeepsReferenceAndClosesItself() async throws {
        let harness = try await E2EHarness.make(routes: routes)
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()

        let engine = try #require(harness.store.engine as? WebKitEngine)
        let opened = await harness.openAndLoad(await harness.server.url("opener"))
        #expect(opened)
        let openerTab = try #require(harness.store.selectedTab)
        let openerPaneID = openerTab.focusedPaneID

        // Click the link. The real WebKit popup path runs: createWebViewWith
        // builds a real popup web view from the opener's configuration, and the
        // store hosts it as a tab. (Restore already made one tab and openAndLoad
        // a second, so the popup is the third.)
        try await evaluate("document.getElementById('go').click()", in: openerPaneID, engine: engine)

        let hasPopup = await harness.wait {
            harness.store.tabs.count == 3
        }
        #expect(hasPopup, "the popup becomes a tab")
        let popupPaneID = try #require(
            harness.store.tabs.first { $0.focusedPane.url.path() == "/popup" }?.focusedPaneID
        )

        // The popup actually navigated — WebKit performed the load into the view
        // it got back, rather than leaving it blank.
        let loaded = await harness.wait {
            harness.store.tabs.first { $0.focusedPaneID == popupPaneID }?.displayTitle
                == "Popup Page"
        }
        #expect(loaded, "the popup view loads its destination")

        // The load-bearing assertion: the opener's window.open() got a real
        // reference it can poll or read the auth result from. A plain store tab
        // would have returned null here.
        let hasReference = try await evaluate(
            "window.myWin !== null", in: openerPaneID, engine: engine
        ) as? Bool
        #expect(hasReference == true, "window.open() must return a live window reference")

        // window.close() closes the popup tab — the auth popup tidies up after
        // itself instead of lingering.
        try await evaluate("window.close()", in: popupPaneID, engine: engine)
        let closed = await harness.wait { harness.store.tabs.count == 2 }
        #expect(closed, "window.close() closes the popup tab")
        #expect(harness.store.selectedTab?.focusedPaneID == openerPaneID)

        // The opener's reference reports the popup as closed, which is what a
        // polling login page uses to notice the flow finished.
        let popupIsClosed = try await evaluate(
            "window.myWin.closed === true", in: openerPaneID, engine: engine
        ) as? Bool
        #expect(popupIsClosed == true, "the opener sees its popup close")
    }

    /// Runs JavaScript in a pane's live web view, reaching the engine's pool
    /// the way the app's web-extension host does. The test target imports
    /// WebKit because only the engine may; no production code path needs this.
    @discardableResult
    private func evaluate(
        _ script: String, in paneID: UUID, engine: WebKitEngine
    ) async throws -> Any? {
        let webView = try #require(engine.pool.view(for: paneID)?.webView)
        return try await webView.evaluateJavaScript(script)
    }
}
