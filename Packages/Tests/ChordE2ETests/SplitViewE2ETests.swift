import ChordCore
import ChordStore
import ChordTestSupport
import Foundation
import Testing

/// Split view against the real stack (4.5).
///
/// The unit tests prove the fraction maths and the store transitions. These
/// prove the part only the real engine can: that two live web views coexist in
/// one tab, navigate independently, and both come back after a relaunch.
@Suite("E2E: split view")
@MainActor
struct SplitViewE2ETests {

    private static func routes() -> [TestHTTPServer.Route] {
        [
            .init(path: "/left", html: "<html><head><title>Left</title></head><body>L</body></html>"),
            .init(path: "/right", html: "<html><head><title>Right</title></head><body>R</body></html>"),
            .init(path: "/second", html: "<html><head><title>Second</title></head><body>2</body></html>"),
        ]
    }

    @Test("Two panes in one tab each get their own live web view")
    func splitCreatesTwoLiveViews() async throws {
        let harness = try await E2EHarness.make(routes: Self.routes())
        defer { Task { await harness.tearDown() } }

        await harness.store.restore()
        #expect(await harness.openAndLoad(await harness.server.url("/left")))

        harness.store.splitSelectedTab(url: await harness.server.url("/right"))

        let tab = try #require(harness.store.selectedTab)
        #expect(tab.panes.count == 2)

        // Rendering both panes is what the split content view does; each must
        // get its own surface, not share the focused pane's.
        for pane in tab.panes {
            _ = harness.store.surface(for: pane, in: tab)
        }

        let loaded = await harness.wait {
            tab.panes.allSatisfy { !harness.store.runtime(for: $0.id).isLoading }
        }
        #expect(loaded)
        #expect(harness.store.liveWebViewCount == 2)
    }

    @Test("Navigating one pane leaves the other alone")
    func panesNavigateIndependently() async throws {
        let harness = try await E2EHarness.make(routes: Self.routes())
        defer { Task { await harness.tearDown() } }

        await harness.store.restore()
        #expect(await harness.openAndLoad(await harness.server.url("/left")))
        harness.store.splitSelectedTab(url: await harness.server.url("/right"))

        var tab = try #require(harness.store.selectedTab)
        let leftPane = tab.panes[0]
        let rightPane = tab.panes[1]
        for pane in tab.panes { _ = harness.store.surface(for: pane, in: tab) }
        _ = await harness.wait {
            tab.panes.allSatisfy { !harness.store.runtime(for: $0.id).isLoading }
        }

        // The focused pane is the new right-hand one; navigation acts on it.
        harness.store.navigate(to: await harness.server.url("/second"))
        _ = await harness.wait {
            harness.store.runtime(for: rightPane.id).currentURL?.path == "/second"
        }

        tab = try #require(harness.store.selectedTab)
        #expect(tab.pane(rightPane.id)?.url.path == "/second")
        // 4.5: each pane has independent navigation. The left one must not have
        // followed along.
        #expect(tab.pane(leftPane.id)?.url.path == "/left")
    }

    @Test("A split tab restores both panes, widths and all")
    func splitSurvivesRelaunch() async throws {
        let harness = try await E2EHarness.make(routes: Self.routes())
        defer { Task { await harness.tearDown() } }

        await harness.store.restore()
        #expect(await harness.openAndLoad(await harness.server.url("/left")))
        harness.store.splitSelectedTab(url: await harness.server.url("/right"))

        let original = try #require(harness.store.selectedTab)
        for pane in original.panes { _ = harness.store.surface(for: pane, in: original) }
        _ = await harness.wait {
            original.panes.allSatisfy { !harness.store.runtime(for: $0.id).isLoading }
        }

        // An uneven split, so equal-width fractions cannot pass by accident.
        harness.store.resizePanes(in: original.id, dividerAfter: 0, by: 0.2)
        let expected = try #require(harness.store.selectedTab).panes.map(\.widthFraction)

        await harness.store.flushInteractionState()
        await harness.store.flushSaveAndWait()

        // Relaunch.
        let relaunched = try harness.relaunch()
        await relaunched.restore()

        let restored = try #require(relaunched.tabs.first { $0.id == original.id })
        #expect(restored.panes.count == 2)
        #expect(restored.panes.map(\.url.path) == ["/left", "/right"])

        for (index, pane) in restored.panes.enumerated() {
            #expect(abs(pane.widthFraction - expected[index]) < 0.001)
        }

        // Restore is still lazy: two saved panes, zero web views (6.2).
        #expect(relaunched.liveWebViewCount == 0)
    }

    @Test("The non-focused pane of a restored split keeps its own history")
    func nonFocusedPaneRestoresItsState() async throws {
        // The bug M4 left: `surface(for:)` gated on the tab's *focused* pane, so
        // a second pane could be built before its blob was read — loading the
        // bare URL and discarding the restore. Only a real engine shows it,
        // because only a real engine has back/forward history to lose.
        let harness = try await E2EHarness.make(routes: Self.routes())
        defer { Task { await harness.tearDown() } }

        await harness.store.restore()
        #expect(await harness.openAndLoad(await harness.server.url("/left")))
        harness.store.splitSelectedTab(url: await harness.server.url("/right"))

        let original = try #require(harness.store.selectedTab)
        let leftPane = original.panes[0]
        for pane in original.panes { _ = harness.store.surface(for: pane, in: original) }
        _ = await harness.wait {
            original.panes.allSatisfy { !harness.store.runtime(for: $0.id).isLoading }
        }

        // Give the *non-focused* left pane real back/forward history.
        harness.store.focusPane(leftPane.id)
        harness.store.navigate(to: await harness.server.url("/second"))
        _ = await harness.wait {
            harness.store.runtime(for: leftPane.id).currentURL?.path == "/second"
        }
        // Hand focus back to the right pane, so the left one is not focused when
        // the session is saved — exactly the shape the bug needed.
        harness.store.focusPane(original.panes[1].id)

        await harness.store.flushInteractionState()
        await harness.store.flushSaveAndWait()

        let relaunched = try harness.relaunch()
        await relaunched.restore()

        let restored = try #require(relaunched.tabs.first { $0.id == original.id })
        relaunched.select(restored.id)

        // Render the non-focused pane, the way the split view does.
        let pane = try #require(restored.pane(leftPane.id))
        let appeared = await relaunched_wait(relaunched) {
            relaunched.surface(for: pane, in: restored) != nil
        }
        #expect(appeared, "the non-focused pane never resolved its state")

        // interactionState carries back/forward history. If the pane had been
        // built from its bare URL instead, there would be nothing to go back to.
        let canGoBack = await relaunched_wait(relaunched) {
            relaunched.runtime(for: pane.id).canGoBack
        }
        #expect(canGoBack, "the non-focused pane lost its back/forward history")
    }

    /// Local poll helper — the harness's `wait` is bound to its own store.
    private func relaunched_wait(
        _ store: TabStore,
        timeout: Duration = .seconds(10),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }
}
