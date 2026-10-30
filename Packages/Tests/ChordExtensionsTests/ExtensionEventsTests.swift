import ChordCore
import Foundation
import Testing
import WebKit

@testable import ChordExtensions

/// c1k.5: the shim asked for tab groups every 3 s and idle state every 15 s,
/// for ever, in every worker that listened. Groups are pushed now; idle
/// never changed.
@Suite("Extension events instead of polls", .serialized)
@MainActor
struct ExtensionEventsTests {

    @Test("The shim sets no clock for tab groups or idle state")
    func noPolls() {
        let shim = ExtensionShimScript.javascript
        #expect(!shim.contains("setInterval(groupsChanged"))
        #expect(!shim.contains("idle.queryState\", [every]"))
        #expect(shim.contains("chord.events"))
    }

    @Test("A worker listening to tab groups opens the events port; one that doesn't, doesn't")
    func listenerConnects() async throws {
        ExtensionEvents.reset()
        defer { ExtensionEvents.reset() }
        let quiet = try await loadWorker("quiet", "self.started = true;")
        defer { quiet() }
        try await Task.sleep(for: .milliseconds(500))
        #expect(ExtensionEvents.listening == 0)

        let listening = try await loadWorker(
            "groups", "chrome.tabGroups.onUpdated.addListener(() => {});"
        )
        defer { listening() }
        for _ in 0..<60 where ExtensionEvents.listening == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(ExtensionEvents.listening == 1)
    }

    private func loadWorker(_ slug: String, _ source: String) async throws -> () -> Void {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ext-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
            { "manifest_version": 3, "name": "\(slug)", "version": "1.0",
              "permissions": ["tabGroups"],
              "background": { "service_worker": "worker.js" } }
            """.write(to: dir.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try source.write(to: dir.appending(path: "worker.js"), atomically: true, encoding: .utf8)
        try ExtensionShims.prepare(dir, fresh: true)
        let host = WebKitExtensionHost()
        let space = Space(name: slug, sortIndex: 0)
        let identifier = String(repeating: slug == "quiet" ? "d" : "e", count: 32)
        _ = try await host.load(
            InstalledExtension(slug: slug, identifier: identifier, resourceURL: dir), in: space
        )
        let context = try #require(host.context(forSlug: slug, in: space))
        try await context.loadBackgroundContent()
        return { _ = host; try? FileManager.default.removeItem(at: dir) }
    }
}

/// c1k.8: the shim runs in every extension page and worker.
@Suite("Perf budget: extension shim")
struct ShimPerfBudgetTests {
    @Test("The shim sets no repeating timer")
    func noIntervals() {
        let found = ExtensionShimScript.javascript.components(separatedBy: "setInterval(").count - 1
        #expect(found == 0, "the shim has \(found) setInterval: over the perf budget, see docs/perf/BUDGETS.md")
    }
}
