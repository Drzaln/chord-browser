import ChordCore
import Foundation
import Testing

@testable import ChordExtensions

/// 9ba: what an extension's scripts throw reaches the host, once per message,
/// with the line in the extension's own terms.
@MainActor
struct ExtensionScriptErrorsTests {
    @Test func aRepeatedMessageIsNewOnceAndCounted() {
        var log = ExtensionScriptErrorLog()
        #expect(log.record(["Error: a", "Error: a"], key: "s|x") == ["Error: a"])
        // WebKit hands over the whole list again, now longer.
        #expect(log.record(["Error: a", "Error: a", "Error: a", "Error: b"], key: "s|x") == ["Error: b"])
        #expect(log.errors(for: "s|x") == [
            ExtensionScriptError(message: "Error: a", count: 3),
            ExtensionScriptError(message: "Error: b", count: 1),
        ])
        #expect(log.errors(for: "s|other").isEmpty)
        log.forget("s|x")
        #expect(log.errors(for: "s|x").isEmpty)
    }

    @Test func onlyTheNewestDistinctMessagesAreKept() {
        var log = ExtensionScriptErrorLog()
        let messages = (0..<(ExtensionScriptErrorLog.limit + 5)).map { "Error: \($0)" }
        _ = log.record(messages, key: "k")
        let kept = log.errors(for: "k")
        #expect(kept.count == ExtensionScriptErrorLog.limit)
        #expect(kept.last?.message == messages.last)
    }

    @Test func theShimsLinesComeOffTheWorkersLineNumbers() {
        let message = "Error: x (background.js:3386:102)"
        #expect(
            ExtensionScriptErrorLog.withShimRemoved(from: message, workerFile: "background.js", offset: 3383)
                == "Error: x (background.js:3:102)"
        )
        // Another file of the extension's is left alone, as is a line inside
        // the shim itself.
        #expect(
            ExtensionScriptErrorLog.withShimRemoved(from: "Error: y (popup.js:40:1)", workerFile: "background.js", offset: 3383)
                == "Error: y (popup.js:40:1)"
        )
        #expect(
            ExtensionScriptErrorLog.withShimRemoved(from: "Error: z (background.js:12:1)", workerFile: "background.js", offset: 3383)
                == "Error: z (background.js:12:1)"
        )
    }

    /// The Safari 27 runtime (macOS 27) reports both; earlier ones report
    /// neither, so the test is skipped there.
    @Test func aWorkersExceptionAndRejectionReachTheHost() async throws {
        guard #available(macOS 27, *) else { return }
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "chord-errors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try """
            {
              "manifest_version": 3,
              "name": "Error Probe",
              "description": "Throws on purpose.",
              "version": "1.0",
              "background": { "service_worker": "bg.js" }
            }
            """.write(to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try """
            chrome.runtime.onConnect.addListener(() => {});
            setTimeout(() => { throw new Error("probe boom"); }, 50);
            Promise.reject(new Error("probe reject"));
            """.write(to: folder.appending(path: "bg.js"), atomically: true, encoding: .utf8)
        try ExtensionShims.prepare(folder, fresh: true)

        let host = WebKitExtensionHost()
        let space = Space(name: "Probe", sortIndex: 0)
        let installed = InstalledExtension(
            slug: "error-probe", identifier: String(repeating: "c", count: 32), resourceURL: folder
        )
        _ = try await host.load(installed, in: space)
        defer { try? host.unload(slug: installed.slug, in: space) }

        var errors = host.scriptErrors(slug: installed.slug, in: space)
        for _ in 0..<50 where errors.count < 2 {
            try await Task.sleep(for: .milliseconds(100))
            errors = host.scriptErrors(slug: installed.slug, in: space)
        }
        let messages = errors.map(\.message)
        #expect(messages.contains("Error: probe reject"), "\(messages)")
        #expect(messages.contains { $0.hasPrefix("Error: probe boom (bg.js:2:") }, "\(messages)")
    }
}
