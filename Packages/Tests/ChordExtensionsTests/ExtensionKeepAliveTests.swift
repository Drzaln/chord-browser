import ChordCore
import Foundation
import Testing
import WebKit

@testable import ChordExtensions

/// c1k.9: a worker WebKit keeps unloading and an event keeps starting again
/// cost a web process launch each time. One woken again soon is held.
@Suite("Worker keep-alive", .serialized)
@MainActor
struct ExtensionKeepAliveTests {

    @Test("A first start isn't held; a start soon after is; a slow one isn't")
    func holdPolicy() {
        ExtensionKeepAlive.reset()
        defer { ExtensionKeepAlive.reset() }
        let start = Date()
        #expect(!ExtensionKeepAlive.shouldHold("a", now: start))
        // Unloaded at 30 s, its alarm starts it again on the minute.
        #expect(ExtensionKeepAlive.shouldHold("a", now: start.addingTimeInterval(60)))
        // A worker woken every five minutes keeps unloading as before.
        #expect(!ExtensionKeepAlive.shouldHold("b", now: start))
        #expect(!ExtensionKeepAlive.shouldHold("b", now: start.addingTimeInterval(300)))
    }

    @Test("A hold goes on while the worker is still woken, and ends once it isn't")
    func renewPolicy() {
        ExtensionKeepAlive.reset()
        defer { ExtensionKeepAlive.reset() }
        let start = Date()
        // Never said it woke: the hold ends as before.
        #expect(!ExtensionKeepAlive.shouldRenew("a", now: start))
        // Its alarm reached it a minute before the hold ran out.
        ExtensionKeepAlive.noteWoken("a", now: start)
        #expect(ExtensionKeepAlive.shouldRenew("a", now: start.addingTimeInterval(60)))
        // Nothing for longer than a cycle: let go.
        #expect(!ExtensionKeepAlive.shouldRenew("a", now: start.addingTimeInterval(300)))
        ExtensionKeepAlive.forget("a")
        #expect(!ExtensionKeepAlive.shouldRenew("a", now: start))
    }

    @Test("A tree stamped before a shim change is out of date, so it gets the new shim")
    func shimChangeReachesInstalls() {
        // What every install prepared since the shim was added carries.
        #expect(!ExtensionShims.isCurrent(stamp: "2-worker-0"))
        #expect(ExtensionShims.isCurrent(stamp: ExtensionShims.stampValue(workerGeneration: 3)))
        #expect(ExtensionShims.stampValue(workerGeneration: 0).contains(ExtensionShims.fingerprint))
    }

    @Test("A worker's shim asks for the keep-alive port as it starts")
    func shimAsks() async throws {
        ExtensionKeepAlive.reset()
        defer { ExtensionKeepAlive.reset() }
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ext-keepalive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
            { "manifest_version": 3, "name": "Alarm", "version": "1.0",
              "background": { "service_worker": "worker.js" } }
            """.write(to: dir.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try "self.started = true;".write(
            to: dir.appending(path: "worker.js"), atomically: true, encoding: .utf8
        )
        try ExtensionShims.prepare(dir, fresh: true)

        let host = WebKitExtensionHost()
        let space = Space(name: "Alarm", sortIndex: 0)
        let identifier = String(repeating: "c", count: 32)
        _ = try await host.load(
            InstalledExtension(slug: "alarm", identifier: identifier, resourceURL: dir), in: space
        )
        let context = try #require(host.context(forSlug: "alarm", in: space))
        try await context.loadBackgroundContent()

        let key = WebKitExtensionHost.keepAliveKey(space.id, identifier)
        for _ in 0..<60 where !ExtensionKeepAlive.hasSeen(key) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(ExtensionKeepAlive.hasSeen(key))
        // Its first start: nothing to hold yet.
        #expect(!ExtensionKeepAlive.isHolding(key))
    }

    @Test("A message reaching a held worker tells the browser it is still woken (c1k.14)")
    func heldWorkerSaysWoken() async throws {
        ExtensionKeepAlive.reset()
        defer { ExtensionKeepAlive.reset() }
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ext-keepalive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
            { "manifest_version": 3, "name": "Woken", "version": "1.0",
              "permissions": ["offscreen"],
              "background": { "service_worker": "worker.js" } }
            """.write(to: dir.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try "chrome.runtime.onMessage.addListener((m, s, reply) => { reply(\"ok\"); });".write(
            to: dir.appending(path: "worker.js"), atomically: true, encoding: .utf8
        )
        try "<!doctype html><body>page</body>".write(
            to: dir.appending(path: "page.html"), atomically: true, encoding: .utf8
        )
        try ExtensionShims.prepare(dir, fresh: true)

        let host = WebKitExtensionHost()
        let space = Space(name: "Woken", sortIndex: 0)
        let identifier = String(repeating: "d", count: 32)
        let key = WebKitExtensionHost.keepAliveKey(space.id, identifier)
        // As though it had started a minute ago: this start is held.
        _ = ExtensionKeepAlive.shouldHold(key, now: Date().addingTimeInterval(-60))
        _ = try await host.load(
            InstalledExtension(slug: "woken", identifier: identifier, resourceURL: dir), in: space
        )
        let context = try #require(host.context(forSlug: "woken", in: space))
        try await context.loadBackgroundContent()
        for _ in 0..<60 where !ExtensionKeepAlive.isHolding(key) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(ExtensionKeepAlive.isHolding(key))
        #expect(!ExtensionKeepAlive.shouldRenew(key))

        _ = try await ExtensionShimBroker.answer(
            ["api": "offscreen.createDocument",
             "args": [["url": "page.html", "reasons": ["DOM_PARSER"]]]],
            context: context, spaceID: space.id, host: host
        )
        let page = try #require(ExtensionOffscreen.webView(identifier: identifier, spaceID: space.id))
        let reply = try await page.callAsyncJavaScript(
            "return await chrome.runtime.sendMessage({ hello: true });",
            arguments: [:], in: nil, contentWorld: .page
        )
        #expect(reply as? String == "ok")
        for _ in 0..<60 where !ExtensionKeepAlive.shouldRenew(key) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(ExtensionKeepAlive.shouldRenew(key))
    }
}
