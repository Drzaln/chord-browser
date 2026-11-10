import ChordStore
import ChordTestSupport
import Foundation
import Testing
import WebKit

@testable import ChordEngine

/// End-to-end: a load that really fails, in a real `WKWebView`, ends on the
/// error page while the app still sees the address that failed.
@Suite("E2E: error page", .serialized)
@MainActor
struct ErrorPageE2ETests {
    /// An address nothing listens on, so the connection is refused at once: a
    /// port the system just handed out and that was closed again. (Not a low
    /// port: WebKit refuses those itself, with an error of its own.)
    private let dead: URL = {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(fd, $0, length)
                _ = getsockname(fd, $0, &length)
            }
        }
        return URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/nothing-here")!
    }()

    @Test("A refused connection shows the error page at the address that failed")
    func refusedConnection() async throws {
        let harness = try await E2EHarness.make(routes: [])
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()

        harness.store.newTab(url: dead)
        let tab = try #require(harness.store.selectedTab)
        _ = harness.store.surface(for: tab)
        let paneID = tab.focusedPaneID

        let shown = await harness.wait {
            ErrorPage.isErrorPage(harness.engine.pool.peek(paneID)?.webView.url)
                && !harness.store.runtime(for: paneID).isLoading
        }
        #expect(shown)

        // The app is told the pane is at the address the user asked for.
        #expect(harness.store.runtime(for: paneID).currentURL == dead)
        #expect(harness.store.selectedTab?.focusedPane.url == dead)
        #expect(harness.store.selectedTab?.displayTitle == "127.0.0.1")

        let view = try #require(harness.engine.pool.peek(paneID)?.webView)
        let headline = try await view.evaluateJavaScript("document.querySelector('h1').textContent")
        #expect(headline as? String == "Chord can’t connect to 127.0.0.1")
        let retryHidden = try await view.evaluateJavaScript("document.getElementById('retry').hidden")
        #expect(retryHidden as? Bool == false)

        // A failed load is not a visit.
        try? await Task.sleep(for: .milliseconds(300))
        let history = await harness.store.loadFullHistory(in: harness.store.focusedWindow)
        #expect(!history.contains { $0.url == dead })
    }

    @Test("A reload retries the address that failed, and a page that works replaces the error")
    func reloadRetries() async throws {
        let harness = try await E2EHarness.make(routes: [.page(path: "/home", title: "Home Page")])
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()

        let home = await harness.server.url("home")
        #expect(await harness.openAndLoad(home))
        let paneID = try #require(harness.store.selectedTab?.focusedPaneID)

        // Stand the error page in for the page that works, as a failed load would.
        harness.engine.presentErrorPage(for: paneID, failedURL: home, code: NSURLErrorTimedOut)
        let shown = await harness.wait {
            ErrorPage.isErrorPage(harness.engine.pool.peek(paneID)?.webView.url)
                && !harness.store.runtime(for: paneID).isLoading
        }
        #expect(shown)
        #expect(harness.store.runtime(for: paneID).currentURL == home)

        harness.engine.reload(paneID: paneID)
        let retried = await harness.wait {
            harness.engine.pool.peek(paneID)?.webView.url == home
                && !harness.store.runtime(for: paneID).isLoading
                && harness.store.selectedTab?.displayTitle == "Home Page"
        }
        #expect(retried)
    }

    @Test("A link no app handles leaves the page it was clicked on alone")
    func unsupportedSchemeKeepsThePage() async throws {
        let harness = try await E2EHarness.make(routes: [.page(path: "/home", title: "Home Page")])
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()

        let home = await harness.server.url("home")
        #expect(await harness.openAndLoad(home))
        let paneID = try #require(harness.store.selectedTab?.focusedPaneID)
        let view = try #require(harness.engine.pool.peek(paneID)?.webView)

        _ = try? await view.evaluateJavaScript("location.href = 'chord-no-such-app://open'; 0")
        try? await Task.sleep(for: .milliseconds(600))
        #expect(view.url == home)
        #expect(harness.store.runtime(for: paneID).currentURL == home)
    }
}
