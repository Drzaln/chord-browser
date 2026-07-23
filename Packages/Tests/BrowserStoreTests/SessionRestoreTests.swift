import BrowserCore
import BrowserEngine
import BrowserStore
import BrowserTestSupport
import Foundation
import Testing

/// M4: `interactionState` capture and restore.
@Suite("Session restore")
@MainActor
struct SessionRestoreTests {

    private func makeStore(
        stored: [Tab] = [],
        spaces: [Space] = []
    ) -> (TabStore, FakeWebEngine, FakeTabRepository) {
        let engine = FakeWebEngine()
        let repository = FakeTabRepository(stored: stored, spaces: spaces)
        let store = TabStore(
            engine: engine,
            repository: repository,
            spaceRepository: repository,
            clock: FixedClock()
        )
        return (store, engine, repository)
    }

    /// The gap this milestone exists to close: before M4, state was captured
    /// only on eviction, so a tab you merely switched away from persisted
    /// nothing and came back as a fresh page load.
    @Test("Switching away from a tab persists its interaction state")
    func capturesOnDeactivation() async throws {
        let first = TabBuilder().url("https://first.example").build()
        let second = TabBuilder().url("https://second.example").build()
        let (store, engine, repository) = makeStore(stored: [first, second])

        await store.restore()
        store.select(first.id)
        // Make the pane live, as showing it would. The surface is withheld
        // until the pane's stored state has been read.
        await settle { store.surface(for: store.tabs[0]) != nil }

        let state = Data("scrolled halfway".utf8)
        engine.interactionStates[first.paneID] = state

        store.select(second.id)

        let saved = try await storedState(repository, paneID: first.paneID)
        #expect(saved == state)
    }

    @Test("A pane with no live view is not persisted over what is on disk")
    func doesNotCaptureDeadPanes() async throws {
        let first = TabBuilder().url("https://first.example").build()
        let second = TabBuilder().url("https://second.example").build()
        let (store, _, repository) = makeStore(stored: [first, second])

        let existing = Data("from a previous session".utf8)
        try await repository.saveInteractionState(existing, paneID: first.paneID)

        await store.restore()
        // Never shown, so never live.
        store.select(second.id)

        let saved = try await storedState(repository, paneID: first.paneID)
        #expect(saved == existing)
    }

    @Test("A restored pane is seeded from disk before its view is built")
    func seedsOnActivation() async throws {
        let tab = TabBuilder().url("https://example.com").build()
        let (store, engine, repository) = makeStore(stored: [tab])

        let state = Data("previous session".utf8)
        try await repository.saveInteractionState(state, paneID: tab.paneID)

        await store.restore()
        // The blob is read asynchronously; the surface is withheld until then.
        #expect(store.surface(for: store.tabs[0]) == nil)

        await settle { engine.seededStates[tab.paneID] != nil }

        #expect(engine.seededStates[tab.paneID] == state)
        // Only now may a view be built, and it is built from state.
        #expect(store.surface(for: store.tabs[0]) != nil)
    }

    /// Withholding the surface must not strand a pane that has nothing stored,
    /// or a fresh profile would render a blank window forever.
    @Test("A pane with no stored state still gets a view")
    func resolvesWhenNothingStored() async {
        let tab = TabBuilder().url("https://example.com").build()
        let (store, engine, _) = makeStore(stored: [tab])

        await store.restore()
        await settle { store.surface(for: store.tabs[0]) != nil }

        #expect(engine.seededStates.isEmpty)
        #expect(store.surface(for: store.tabs[0]) != nil)
    }

    @Test("Reading state for restore still creates no web views")
    func restoreStaysLazy() async throws {
        let stored = (0..<5).map { TabBuilder().url("https://\($0).example").build() }
        let (store, engine, repository) = makeStore(stored: stored)

        for tab in stored {
            try await repository.saveInteractionState(Data("s".utf8), paneID: tab.paneID)
        }

        await store.restore()
        // Give every pending read every chance to run. This asserts an absence,
        // so waiting longer can only strengthen it.
        await drain()

        // Restore reads at most the selected tab's blob and builds nothing (6.2).
        #expect(engine.liveViewCount() == 0)
    }

    @Test("Closing a tab reclaims its stored state")
    func prunesOnClose() async throws {
        let keep = TabBuilder().url("https://keep.example").build()
        let close = TabBuilder().url("https://close.example").build()
        let (store, _, repository) = makeStore(stored: [keep, close])

        try await repository.saveInteractionState(Data("a".utf8), paneID: keep.paneID)
        try await repository.saveInteractionState(Data("b".utf8), paneID: close.paneID)

        await store.restore()
        store.closeTab(close.id)
        await store.flushSaveAndWait()

        // The blob table has no foreign key to `pane`, so nothing else would
        // ever reclaim this (6.5).
        #expect(try await repository.loadInteractionState(paneID: close.paneID) == nil)
        #expect(try await repository.loadInteractionState(paneID: keep.paneID) != nil)
    }

    @Test("Quitting captures every live pane and waits for the writes")
    func flushOnQuit() async throws {
        let first = TabBuilder().url("https://first.example").build()
        let second = TabBuilder().url("https://second.example").build()
        let (store, engine, repository) = makeStore(stored: [first, second])

        await store.restore()
        store.select(first.id)
        await settle { store.surface(for: store.tabs[0]) != nil }
        store.select(second.id)
        await settle { store.surface(for: store.tabs[1]) != nil }

        engine.interactionStates[first.paneID] = Data("one".utf8)
        engine.interactionStates[second.paneID] = Data("two".utf8)

        await store.flushInteractionState()

        // Awaited, not fire-and-forget: on the quit path a detached task never
        // runs before the process is gone.
        #expect(try await repository.loadInteractionState(paneID: first.paneID) != nil)
        #expect(try await repository.loadInteractionState(paneID: second.paneID) != nil)
    }

    @Test("Hiding the window captures state, since the app may never come back")
    func capturesOnOcclusion() async throws {
        let tab = TabBuilder().url("https://example.com").build()
        let (store, engine, repository) = makeStore(stored: [tab])

        await store.restore()
        await settle { store.surface(for: store.tabs[0]) != nil }
        engine.interactionStates[tab.paneID] = Data("state".utf8)

        store.setOccluded(true)

        #expect(try await storedState(repository, paneID: tab.paneID) != nil)
    }
}

extension Tab {
    /// The pane every single-pane test tab has.
    var paneID: UUID { panes[0].id }
}

/// Capture and resolution both hop through a detached task and an actor, so a
/// single `Task.yield()` is not a barrier. These retry instead of sleeping, so
/// they are neither flaky nor slow.
/// Capture and resolution hop through a detached main-actor task and an actor,
/// so waiting has to yield *time*, not just a suspension point. `Task.yield()`
/// alone is not enough: the whole test suite runs in parallel, and under that
/// contention a pending main-actor task may not be scheduled for many yields.
/// These poll on a short sleep and return as soon as the condition holds, so
/// they cost milliseconds in practice rather than the full budget.
private let pollInterval = Duration.milliseconds(5)
private let pollAttempts = 400  // 2s worst case

private func tick() async { try? await Task.sleep(for: pollInterval) }

/// Lets pending work run, for assertions about something *not* happening.
private func drain() async {
    for _ in 0..<20 { await tick() }
}

@MainActor
private func settle(until condition: () -> Bool) async {
    for _ in 0..<pollAttempts {
        if condition() { return }
        await tick()
    }
}

private func storedState(
    _ repository: FakeTabRepository, paneID: UUID
) async throws -> Data? {
    for _ in 0..<pollAttempts {
        if let data = try await repository.loadInteractionState(paneID: paneID) { return data }
        await tick()
    }
    return nil
}
