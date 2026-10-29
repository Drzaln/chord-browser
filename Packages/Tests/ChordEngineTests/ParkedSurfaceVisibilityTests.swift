import AppKit
import SwiftUI
import Testing
import WebKit

@testable import ChordEngine

/// A parked tab stays mounted (detaching it resets SPA state), so the only
/// way WebKit learns it is in the background is the view being hidden. A view
/// merely covered by the selected tab counts as visible: no hidden-page
/// throttling, timers and animations at full rate.
@Suite("Parked surface visibility", .serialized)
@MainActor
struct ParkedSurfaceVisibilityTests {

    private func visibility(of webView: WKWebView, becomes state: String) async -> String? {
        var current: String?
        for _ in 0..<60 {
            current = try? await webView.evaluateJavaScript("document.visibilityState") as? String
            if current == state { return current }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return current
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    /// A test process's window never counts as on screen (its occlusion state
    /// is never `.visible`), so every page in it reads "hidden" whatever the
    /// app does. Turning WebKit's occlusion check off for the test leaves the
    /// view's own hidden state as the only signal, which is the one under test.
    private func loadedWebView() -> WKWebView {
        // The engine's own configuration, so its scheduling policy is the one
        // in force.
        let configuration = WebKitEngine.configurationTemplate.copy() as! WKWebViewConfiguration
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if webView.responds(to: selector) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(webView.method(for: selector), to: Setter.self)(webView, selector, false)
        }
        webView.loadHTMLString("<body>page</body>", baseURL: URL(string: "https://example.com/"))
        return webView
    }

    @Test("Covered by a sibling, a page still reports visible")
    func coveredIsStillVisible() async throws {
        let window = makeWindow()
        defer { window.close() }
        let container = WebSurfaceContainerView(cornerRadius: 0)
        container.frame = window.contentView!.bounds
        window.contentView!.addSubview(container)
        let webView = loadedWebView()
        container.install(webView)
        #expect(await visibility(of: webView, becomes: "visible") == "visible")

        let cover = NSView(frame: container.frame)
        cover.wantsLayer = true
        cover.layer?.backgroundColor = NSColor.white.cgColor
        window.contentView!.addSubview(cover)
        try await Task.sleep(for: .milliseconds(500))

        #expect(try await webView.evaluateJavaScript("document.visibilityState") as? String == "visible")
    }

    @Test("A parked surface hides its page, and unparking shows it again")
    func parkingHidesThePage() async {
        let window = makeWindow()
        defer { window.close() }
        let webView = loadedWebView()
        let container = WebSurfaceContainerView(cornerRadius: 0)
        container.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        container.install(webView)
        let surface = AnyWebSurface(id: UUID(), container: container)
        let host = NSHostingView(rootView: surface.parked(false))
        host.frame = window.contentView!.bounds
        window.contentView!.addSubview(host)
        #expect(await visibility(of: webView, becomes: "visible") == "visible")

        host.rootView = surface.parked(true)
        #expect(await visibility(of: webView, becomes: "hidden") == "hidden")
        #expect(webView.frame.size != .zero, "parking keeps the view's size")

        host.rootView = surface.parked(false)
        #expect(await visibility(of: webView, becomes: "visible") == "visible")
    }

    @Test("A parked page is throttled, not suspended: its timers keep firing")
    func parkedPageKeepsRunning() async throws {
        let window = makeWindow()
        defer { window.close() }
        let webView = loadedWebView()
        let container = WebSurfaceContainerView(cornerRadius: 0)
        container.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        container.install(webView)
        let surface = AnyWebSurface(id: UUID(), container: container)
        let host = NSHostingView(rootView: surface.parked(true))
        host.frame = window.contentView!.bounds
        window.contentView!.addSubview(host)
        #expect(await visibility(of: webView, becomes: "hidden") == "hidden")

        // Wait for the page itself, or the timer below lands on the
        // about:blank before it and goes with it.
        for _ in 0..<60 {
            let href = try? await webView.evaluateJavaScript("location.href") as? String
            if href == "https://example.com/" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        // What background music needs to move to its next track. Hidden, the
        // timer is clamped to about once a second; suspended, it would stop.
        _ = try await webView.evaluateJavaScript(
            "window.ticks = 0; setInterval(() => window.ticks++, 100); 0"
        )
        try await Task.sleep(for: .seconds(3))
        let ticks = try await webView.evaluateJavaScript("window.ticks") as? Int ?? 0
        #expect(ticks >= 2, "a hidden page's timers are clamped, not stopped (\(ticks))")
    }
}
