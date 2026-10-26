import ChordCore
import Foundation
import Testing

@testable import ChordExtensions

/// 899/worker recovery: the generation and observation rules the shim relies
/// on.
///
/// No WebKit here: the delegate callback that feeds `created(_:in:)` needs a
/// loaded context, so these tests exercise the state machine it feeds — which
/// is where every ordering bug lives (answer-before-register, a stale number
/// treated as current, a cancelled observation left holding a reply).
@MainActor
struct ExtensionWorkerRecoveryTests {
    private func key(_ slug: String = "vault") -> ExtensionWorkerRecovery.Key {
        ExtensionWorkerRecovery.Key(spaceID: UUID(), slug: slug)
    }

    @Test func aNewExtensionIsAtGenerationZero() {
        let recovery = ExtensionWorkerRecovery()
        #expect(recovery.generation(for: key()) == 0)
    }

    @Test func replacingTheContextRaisesTheGeneration() {
        let recovery = ExtensionWorkerRecovery()
        let key = key()
        recovery.restarted(key, replacingContext: true)
        #expect(recovery.generation(for: key) == 1)
        recovery.restarted(key, replacingContext: true)
        #expect(recovery.generation(for: key) == 2)
        // The same context reloaded only replaces the background: pages keep
        // their WebKit API objects, so the number they expect stays valid.
        recovery.restarted(key, replacingContext: false)
        #expect(recovery.generation(for: key) == 2)
    }

    @Test func aStaleObserverIsAnsweredAtOnce() async {
        let recovery = ExtensionWorkerRecovery()
        let key = key()
        recovery.restarted(key, replacingContext: true)
        let answer = await recovery.observe(key, generation: 0, token: "t1")
        #expect(answer == 1)
    }

    @Test func aCurrentObserverWaitsForTheNextReplacement() async {
        let recovery = ExtensionWorkerRecovery()
        let key = key()
        let task = Task { await recovery.observe(key, generation: 0, token: "t1") }
        // Let the observation register before the replacement.
        await Task.yield()
        recovery.restarted(key, replacingContext: true)
        #expect(await task.value == 1)
    }

    @Test func cancellingAnswersTheWaitingObserverWithNothing() async {
        let recovery = ExtensionWorkerRecovery()
        let key = key()
        let task = Task { await recovery.observe(key, generation: 0, token: "t1") }
        await Task.yield()
        recovery.cancel(key, token: "t1")
        #expect(await task.value == nil)
        // A cancellation of an unknown token is a no-op, not a crash.
        recovery.cancel(key, token: "never-registered")
    }

    @Test func unregisteringAnswersEveryObserverWithNothing() async {
        let recovery = ExtensionWorkerRecovery()
        let key = key()
        let first = Task { await recovery.observe(key, generation: 0, token: "t1") }
        let second = Task { await recovery.observe(key, generation: 0, token: "t2") }
        await Task.yield()
        recovery.unregister(key)
        #expect(await first.value == nil)
        #expect(await second.value == nil)
    }

    @Test func twoExtensionsInOneSpaceDoNotShareGenerations() {
        let recovery = ExtensionWorkerRecovery()
        let space = UUID()
        let vault = ExtensionWorkerRecovery.Key(spaceID: space, slug: "vault")
        let clipper = ExtensionWorkerRecovery.Key(spaceID: space, slug: "clipper")
        recovery.restarted(vault, replacingContext: true)
        #expect(recovery.generation(for: vault) == 1)
        #expect(recovery.generation(for: clipper) == 0)
    }

    @Test func aTokenLongerThanTheWireLimitIsRefused() async {
        let recovery = ExtensionWorkerRecovery()
        let key = key()
        let long = String(repeating: "a", count: 129)
        #expect(await recovery.observe(key, generation: 0, token: long) == nil)
        #expect(await recovery.observe(key, generation: 0, token: "") == nil)
    }

    /// The private WebKit delegate is the only signal that a background was
    /// created; a worker that starts and is not recorded here leaves every
    /// stale port alive.
    @Test func loadingARealWorkerRecordsItsLifetime() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "chord-worker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try """
            {
              "manifest_version": 3,
              "name": "Worker Probe",
              "version": "1.0",
              "background": { "service_worker": "bg.js" },
              "permissions": ["storage"]
            }
            """.write(
                to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8
            )
        try "chrome.runtime.onConnect.addListener(() => {});\n"
            .write(to: folder.appending(path: "bg.js"), atomically: true, encoding: .utf8)
        try ExtensionShims.prepare(folder, fresh: true)

        let host = WebKitExtensionHost()
        let space = Space(name: "Probe", sortIndex: 0)
        let installed = InstalledExtension(
            slug: "worker-probe",
            identifier: String(repeating: "a", count: 32),
            resourceURL: folder
        )
        _ = try await host.load(installed, in: space)
        let key = ExtensionWorkerRecovery.Key(
            spaceID: space.id, slug: installed.slug
        )
        var lifetime = host.workerRecovery.backgroundLifetime(for: key)
        for _ in 0..<30 where lifetime == nil {
            try await Task.sleep(for: .milliseconds(100))
            lifetime = host.workerRecovery.backgroundLifetime(for: key)
        }
        #expect(lifetime != nil, "WebKit created a background the host never recorded")
        #expect(host.workerRecovery.generation(for: key) == 0)

        // The shim's native channel is the same state machine.
        host.workerRecovery.restarted(key, replacingContext: true)
        let context = try #require(host.context(forSlug: installed.slug, in: space))
        let answer = try await ExtensionShimBroker.answer(
            ["api": "background.observe", "args": [0, "probe-token"]],
            context: context, spaceID: space.id, host: host
        ) as? [String: Any]
        #expect(answer?["value"] as? Int == 1)
    }
}
