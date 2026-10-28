import Foundation
import Testing
import WebKit

@testable import ChordExtensions
@testable import ChordCore

/// M9d: `desktopCapture` is answered by Chord, not WebKit. A worker's stream
/// id is good once, for one extension, for a minute; the API itself requires
/// the manifest's `desktopCapture`; and the shim speaks the `chordCapture`
/// channel only.
@MainActor
struct ExtensionCaptureTests {
    private func makeContext(
        identifier: String = String(repeating: "a", count: 32),
        permissions: [String] = ["desktopCapture"]
    ) async throws -> (WebKitExtensionHost, WKWebExtensionContext, Space, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "chord-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let list = permissions.map { "\"\($0)\"" }.joined(separator: ", ")
        let manifest = """
            { "manifest_version": 3, "name": "Capture Test", "version": "1.0",
              "permissions": [\(list)] }
            """
        try manifest.write(
            to: dir.appending(path: "manifest.json"), atomically: true, encoding: .utf8
        )
        let host = WebKitExtensionHost()
        let space = Space(name: "Work", sortIndex: 0)
        let installed = InstalledExtension(
            slug: "capture-test", identifier: identifier, resourceURL: dir
        )
        try await host.load(installed, in: space)
        let context = try #require(host.context(forSlug: installed.slug, in: space))
        return (host, context, space, dir)
    }

    @Test func aWorkerTokenIsGoodOnce() async throws {
        let (host, context, _, dir) = try await makeContext()
        defer { try? FileManager.default.removeItem(at: dir) }

        let token = host.capture.grant(for: context)
        #expect(token.count == 32)
        #expect(host.capture.take(token, for: context.uniqueIdentifier))
        // The same id never works twice, even for its own extension.
        #expect(!host.capture.take(token, for: context.uniqueIdentifier))
    }

    @Test func aTokenExpiresAfterAMinute() async throws {
        let (host, _, _, dir) = try await makeContext()
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date()
        let identifier = String(repeating: "a", count: 32)
        let token = host.capture.issue(for: identifier, now: start)

        #expect(!host.capture.take(
            token, for: identifier, now: start.addingTimeInterval(61)
        ))
        // An expired id is gone, not left around to be tried again.
        #expect(!host.capture.take(
            token, for: identifier, now: start.addingTimeInterval(1)
        ))
    }

    @Test func anotherExtensionCannotRedeemTheToken() async throws {
        let (host, context, _, dir) = try await makeContext()
        defer { try? FileManager.default.removeItem(at: dir) }

        let token = host.capture.issue(for: "someone-else")
        #expect(!host.capture.take(token, for: context.uniqueIdentifier))
        // A foreign attempt burns the id, as a stolen stream id would.
        #expect(!host.capture.take(token, for: "someone-else"))
    }

    @Test func desktopCaptureRequiresItsManifestPermission() async throws {
        let (host, context, _, dir) = try await makeContext(permissions: [])
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(!ExtensionCapture.declares(context))
        #expect(host.capture.grant(for: context).isEmpty)
    }

    @Test func unloadingAnExtensionDropsItsUnusedTokens() async throws {
        let (host, context, space, dir) = try await makeContext()
        defer { try? FileManager.default.removeItem(at: dir) }
        let token = host.capture.issue(for: context.uniqueIdentifier)

        try host.unload(slug: "capture-test", in: space)
        #expect(!host.capture.take(token, for: context.uniqueIdentifier))
    }

    @Test func offscreenDocumentIsWiredToTheSameCapture() async throws {
        // The offscreen page records only while Chord's call is in flight;
        // nothing is in flight here, so the answer is "no".
        let (host, context, space, dir) = try await makeContext(
            permissions: ["desktopCapture", "offscreen"]
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
            <!doctype html><html><head></head><body>offscreen</body></html>
            """.write(
                to: dir.appending(path: "offscreen.html"),
                atomically: true, encoding: .utf8
            )
        _ = try await ExtensionShimBroker.answer(
            ["api": "offscreen.createDocument",
             "args": [["url": "offscreen.html", "reasons": ["USER_MEDIA"]]]],
            context: context, spaceID: space.id, host: host
        )
        let web = try #require(ExtensionOffscreen.webView(
            identifier: context.uniqueIdentifier, spaceID: space.id
        ))
        // The page channel is installed on the extension's own configuration
        // and authenticates the offscreen page's Chrome origin.
        let kind = try await web.evaluateJavaScript(
            "typeof window.webkit.messageHandlers.chordCapture"
        )
        #expect(kind as? String == "object")
        let lent = try await web.callAsyncJavaScript(
            "return await window.webkit.messageHandlers.chordCapture.postMessage({op: 'lend'});",
            arguments: [:], in: nil, contentWorld: .page
        ) as? [String: Any]
        #expect(lent?["ok"] as? Bool == true)
        #expect(host.capture.displayDecision(for: web) == 0)
        _ = try await ExtensionShimBroker.answer(
            ["api": "offscreen.closeDocument", "args": []],
            context: context, spaceID: space.id, host: host
        )
    }

    @Test func enginePagesGetTheCaptureChannelAndAnswerNoByDefault() throws {
        let host = WebKitExtensionHost()
        let space = Space(name: "Work", sortIndex: 0)
        let handle = try #require(host.extensionControllerHandle(for: space))
        let controller = WKUserContentController()
        // Twice on purpose: WebKit throws if one handler name is added to the
        // same controller again, and every tab asks for the wiring.
        handle.attachCapture?(controller)
        handle.attachCapture?(controller)

        let web = WKWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )
        #expect(handle.captureDisplayDecision?(web) == 0)
    }

    @Test func shimSpeaksTheChordChannelOnly() {
        let script = ExtensionShims.script
        #expect(script.contains("chordCapture"))
        #expect(script.contains("Symbol.for(\"chord.capture\")"))
        #expect(script.contains("chooseDesktopMedia"))
        #expect(script.contains("cancelChooseDesktopMedia"))
        #expect(!script.contains("searchCapture"))
        #expect(!script.contains("Symbol.for(\"search.capture\")"))
    }
}
