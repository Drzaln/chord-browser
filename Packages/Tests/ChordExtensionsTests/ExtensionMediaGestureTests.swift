import AppKit
import ChordCore
import ChordTestSupport
import Foundation
import Testing
import WebKit

@testable import ChordEngine
@testable import ChordExtensions

/// se2: an extension that plays a sound when you click something on a site:
/// its content script tells its offscreen document (AUDIO_PLAYBACK), which
/// plays it. The document's media never started: WebKit holds a page's media
/// until its view is in a window. The click's activation doesn't reach the
/// document (`pageActive` is false), and on the Mac WebKit doesn't ask for it.
@Suite("Extension media from a click", .serialized)
@MainActor
struct ExtensionMediaGestureTests {
    @Test("A click in a tab sends a message, and the extension's page plays media")
    func clickPlaysMedia() async throws {
        let server = try TestHTTPServer(routes: [
            .init(path: "/site", html: "<!doctype html><title>site</title><body style='margin:0'><button id=b style='width:400px;height:300px'>play</button></body>"),
        ])
        try await server.start()
        defer { Task { await server.stop() } }

        let dir = FileManager.default.temporaryDirectory.appending(path: "media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
            { "manifest_version": 3, "name": "Clicker", "version": "1.0",
              "permissions": ["offscreen"],
              "host_permissions": ["<all_urls>"],
              "background": { "service_worker": "worker.js" },
              "content_scripts": [{ "matches": ["<all_urls>"], "js": ["c.js"] }] }
            """.write(to: dir.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try "void 0;".write(to: dir.appending(path: "worker.js"), atomically: true, encoding: .utf8)
        // The content script hands the click on and shows the answer.
        try """
                document.addEventListener("click", async () => {
              const active = navigator.userActivation ? navigator.userActivation.isActive : null;
              try {
                const reply = await chrome.runtime.sendMessage({ play: true });
                document.title = "done " + JSON.stringify({ clickActive: active, ...reply });
              } catch (e) { document.title = "done " + JSON.stringify({ error: String(e) }); }
            });
            """.write(to: dir.appending(path: "c.js"), atomically: true, encoding: .utf8)
        // A tenth of a second of silence, made here: nothing to fetch.
        try """
            function silence() {
              const rate = 8000, n = rate / 10, b = new DataView(new ArrayBuffer(44 + n));
              const s = (o, t) => { for (let i = 0; i < t.length; i++) b.setUint8(o + i, t.charCodeAt(i)); };
              s(0, "RIFF"); b.setUint32(4, 36 + n, true); s(8, "WAVEfmt "); b.setUint32(16, 16, true);
              b.setUint16(20, 1, true); b.setUint16(22, 1, true); b.setUint32(24, rate, true);
              b.setUint32(28, rate, true); b.setUint16(32, 1, true); b.setUint16(34, 8, true);
              s(36, "data"); b.setUint32(40, n, true);
              for (let i = 0; i < n; i++) b.setUint8(44 + i, 128);
              return URL.createObjectURL(new Blob([b.buffer], { type: "audio/wav" }));
            }
            chrome.runtime.onMessage.addListener((message, sender, reply) => {
              if (!message || !message.play) return;
              const active = navigator.userActivation ? navigator.userActivation.isActive : null;
              const audio = new Audio(silence());
              audio.play().then(
                () => reply({ played: true, pageActive: active }),
                (e) => reply({ played: false, pageActive: active, error: String(e) })
              );
              return true;
            });
            """.write(to: dir.appending(path: "player.js"), atomically: true, encoding: .utf8)
        try "<!doctype html><script src=player.js></script>".write(
            to: dir.appending(path: "player.html"), atomically: true, encoding: .utf8
        )
        try ExtensionShims.prepare(dir, fresh: true)

        let host = WebKitExtensionHost()
        let space = Space(name: "Media", sortIndex: 0)
        let identifier = String(repeating: "e", count: 32)
        _ = try await host.load(
            InstalledExtension(slug: "clicker", identifier: identifier, resourceURL: dir), in: space
        )
        host.setAllHostsAccess(true, slug: "clicker", in: space)
        let context = try #require(host.context(forSlug: "clicker", in: space))
        _ = try await ExtensionShimBroker.answer(
            ["api": "offscreen.createDocument",
             "args": [["url": "player.html", "reasons": ["AUDIO_PLAYBACK"]]]],
            context: context, spaceID: space.id, host: host
        )

        let engine = WebKitEngine(configuration: EngineConfiguration(
            faviconCacheDirectory: FileManager.default.temporaryDirectory
                .appending(path: "engine-\(UUID().uuidString)")
        ))
        engine.extensionControllerProvider = host
        let pane = Pane(url: await server.url("site"))
        _ = engine.surface(for: pane, in: space)
        let web = try #require(engine.pool.peek(pane.id)?.webView)
        // WebKit answers a content script's message only from a tab it knows.
        let tabs = OneTab(ExtensionTabSnapshot(
            id: UUID(), spaceID: space.id, focusedPaneID: pane.id,
            url: pane.url, title: "site", isSelected: true, index: 0
        ))
        host.tabModel = tabs
        host.paneWebViewProvider = engine
        host.extensionTabDidOpen(tabs.tab.id, inSpace: space.id)

        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        web.removeFromSuperview()
        web.frame = window.contentView!.bounds
        window.contentView!.addSubview(web)
        window.makeKeyAndOrderFront(nil)

        for _ in 0..<100 where web.title != "site" || web.isLoading {
            try await Task.sleep(for: .milliseconds(100))
        }
        // Time for the content script to be injected.
        try await Task.sleep(for: .milliseconds(500))

        // Mouse events into the view: a script's click() is no user gesture.
        let point = web.convert(NSPoint(x: 200, y: 150), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ))
            if type == .leftMouseDown { web.mouseDown(with: event) } else { web.mouseUp(with: event) }
        }

        var title = web.title ?? ""
        for _ in 0..<100 where !title.hasPrefix("done") {
            try await Task.sleep(for: .milliseconds(100))
            title = web.title ?? ""
        }
        let json = try #require(title.hasPrefix("done ") ? title.dropFirst(5).data(using: .utf8) : nil)
        let result = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(result["clickActive"] as? Bool == true)
        #expect(result["played"] as? Bool == true, "\(result)")
    }
}

private final class OneTab: ExtensionTabModel {
    let tab: ExtensionTabSnapshot
    init(_ tab: ExtensionTabSnapshot) { self.tab = tab }
    func extensionTabs(inSpace spaceID: UUID) -> [ExtensionTabSnapshot] { [tab] }
    func extensionActiveTab(inSpace spaceID: UUID) -> ExtensionTabSnapshot? { tab }
    func extensionTab(_ tabID: UUID) -> ExtensionTabSnapshot? { tabID == tab.id ? tab : nil }
    func extensionActivateTab(_ tabID: UUID) {}
    func extensionLoadURL(_ url: URL, inTab tabID: UUID) {}
    func extensionReloadTab(_ tabID: UUID, fromOrigin: Bool) {}
    func extensionGoBack(inTab tabID: UUID) {}
    func extensionGoForward(inTab tabID: UUID) {}
    func extensionCloseTab(_ tabID: UUID) {}
}
