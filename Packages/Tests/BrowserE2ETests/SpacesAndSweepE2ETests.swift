import BrowserCore
import BrowserStore
import BrowserTestSupport
import Foundation
import Testing

/// End-to-end proof of M2's done-when: a real page sets a real cookie in one
/// Space, and a real page in another Space cannot see it.
@Suite("E2E: Space isolation", .serialized)
@MainActor
struct SpaceIsolationE2ETests {

    private var routes: [TestHTTPServer.Route] {
        [
            .cookieSetter(path: "/login", title: "Logged In", cookie: "session=alpha"),
            .cookieReporter(path: "/whoami"),
        ]
    }

    @Test("A session in one Space is invisible in another, through the full stack")
    func sessionsAreIsolatedEndToEnd() async throws {
        let harness = try await E2EHarness.make(routes: routes)
        defer { Task { await harness.tearDown() } }

        let store = harness.store
        await store.restore()

        // Space A: load the page that sets a cookie.
        let personal = try #require(store.activeSpace)
        _ = await harness.openAndLoad(await harness.server.url("login"))
        _ = await harness.wait { store.selectedTab?.displayTitle == "Logged In" }

        let cookieInA = await readCookie(harness: harness)
        #expect(cookieInA.contains("session=alpha"))

        // Space B: same origin, different data store.
        let work = store.addSpace(name: "Work")
        #expect(store.activeSpace?.id == work.id)
        #expect(work.dataStoreID != personal.dataStoreID)

        let cookieInB = await readCookie(harness: harness)

        // The entire point of Spaces: the same site, no shared session.
        #expect(!cookieInB.contains("session=alpha"))
    }

    /// Loads /whoami in the active Space and returns whatever `document.cookie`
    /// reported, read back through the page title.
    private func readCookie(harness: E2EHarness) async -> String {
        let store = harness.store
        _ = await harness.openAndLoad(await harness.server.url("whoami"))

        _ = await harness.wait {
            store.selectedTab?.displayTitle.hasPrefix("cookie:") == true
        }
        return store.selectedTab?.displayTitle ?? ""
    }
}

/// End-to-end proof of M3's sweep: an idle tab is closed, archived, and can be
/// found again from the command bar.
@Suite("E2E: ephemeral sweep", .serialized)
@MainActor
struct SweepE2ETests {

    private var routes: [TestHTTPServer.Route] {
        [
            .page(path: "/keep", title: "Keep Me"),
            .page(path: "/stale", title: "Stale Tab"),
        ]
    }

    @Test("An idle tab is swept, archived, and recoverable from the command bar")
    func sweepArchivesAndRestores() async throws {
        let clock = MutableClock()
        let harness = try await E2EHarness.make(routes: routes, clock: clock)
        defer { Task { await harness.tearDown() } }

        let store = harness.store
        await store.restore()

        _ = await harness.openAndLoad(await harness.server.url("stale"))
        _ = await harness.wait { store.selectedTab?.displayTitle == "Stale Tab" }
        let staleID = try #require(store.selectedTabID)

        // Open a second tab and select it, so the stale one is not the current
        // tab — the sweep never closes what you are looking at.
        _ = await harness.openAndLoad(await harness.server.url("keep"))
        _ = await harness.wait { store.selectedTab?.displayTitle == "Keep Me" }

        // Move past the idle window instead of waiting twelve hours.
        clock.advance(by: 13 * 60 * 60)
        await store.sweepNow()

        #expect(!store.tabs.contains { $0.id == staleID })
        #expect(store.tabs.contains { $0.displayTitle == "Keep Me" })

        // Archived, not deleted (4.3) — and findable from the bar.
        await store.prepareCommandBar()
        let results = store.suggestions(for: "Stale")
        let archived = try #require(
            results.first { if case .archived = $0.kind { true } else { false } }
        )

        store.activate(archived)
        #expect(store.tabs.contains { $0.displayTitle == "Stale Tab" })
    }

    @Test("A pinned tab is never swept, however idle")
    func pinnedSurvivesSweep() async throws {
        let clock = MutableClock()
        let harness = try await E2EHarness.make(routes: routes, clock: clock)
        defer { Task { await harness.tearDown() } }

        let store = harness.store
        await store.restore()

        _ = await harness.openAndLoad(await harness.server.url("stale"))
        let pinnedID = try #require(store.selectedTabID)
        store.pin(pinnedID)

        _ = await harness.openAndLoad(await harness.server.url("keep"))

        clock.advance(by: 100 * 60 * 60)
        await store.sweepNow()

        #expect(store.tabs.contains { $0.id == pinnedID })
    }

    @Test("The sweep does not run while the window is occluded")
    func occludedSweepIsPaused() async throws {
        let clock = MutableClock()
        let harness = try await E2EHarness.make(routes: routes, clock: clock)
        defer { Task { await harness.tearDown() } }

        let store = harness.store
        await store.restore()

        _ = await harness.openAndLoad(await harness.server.url("stale"))
        let staleID = try #require(store.selectedTabID)
        _ = await harness.openAndLoad(await harness.server.url("keep"))

        store.setOccluded(true)
        clock.advance(by: 13 * 60 * 60)
        await store.sweepNow()

        // Hidden window means no work at all, sweeping included (6.3).
        #expect(store.tabs.contains { $0.id == staleID })

        store.setOccluded(false)
        await store.sweepNow()
        #expect(!store.tabs.contains { $0.id == staleID })
    }

    @Test("The archive survives a relaunch")
    func archiveIsPersisted() async throws {
        let clock = MutableClock()
        let harness = try await E2EHarness.make(routes: routes, clock: clock)
        defer { Task { await harness.tearDown() } }

        let store = harness.store
        await store.restore()

        _ = await harness.openAndLoad(await harness.server.url("stale"))
        _ = await harness.wait { store.selectedTab?.displayTitle == "Stale Tab" }
        _ = await harness.openAndLoad(await harness.server.url("keep"))

        clock.advance(by: 13 * 60 * 60)
        await store.sweepNow()
        store.flushSave()
        try await Task.sleep(for: .milliseconds(300))

        let relaunched = try harness.relaunch()
        await relaunched.restore()
        await relaunched.prepareCommandBar()

        #expect(relaunched.suggestions(for: "Stale").contains {
            if case .archived = $0.kind { true } else { false }
        })

        relaunched.stopSweep()
    }
}
