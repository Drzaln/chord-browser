import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Observation
import Testing

@testable import ChordStore

/// The engine publishes a snapshot on every KVO change — dozens per page load,
/// most of them only `estimatedProgress`. `@Observable` notifies on every set,
/// equal value or not, so a snapshot must only write what it changes: otherwise
/// a progress tick of any tab redraws the sidebar rows (audio, mute, sleep
/// timer), the screen-share banner in RootView, and every reader of
/// `store.tabs` (perf.6).
@Suite("Snapshot observation scope")
@MainActor
struct SnapshotObservationTests {

    private func makeStore() async -> TabStore {
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: FakeTabRepository(stored: [
                TabBuilder().url("https://example.com").title("Example").build()
            ]),
            clock: FixedClock()
        )
        await store.restore()
        return store
    }

    /// Whether reading `read` is invalidated by running `change`.
    private func invalidates(_ read: () -> Void, by change: () -> Void) -> Bool {
        let fired = Fired()
        withObservationTracking(read) { fired.value = true }
        change()
        return fired.value
    }

    private final class Fired: @unchecked Sendable { var value = false }

    private func loading(_ url: URL, _ progress: Double) -> PaneSnapshot {
        PaneSnapshot(url: url, title: "Example", isLoading: true, estimatedProgress: progress)
    }

    @Test("A progress tick leaves the sidebar's per-tab state alone")
    func progressSparesRowState() async throws {
        let store = await makeStore()
        let paneID = try #require(store.selectedTab?.focusedPaneID)
        let url = URL(string: "https://example.com")!
        store.paneDidUpdate(paneID, snapshot: loading(url, 0.1))
        let runtime = store.runtime(for: paneID)

        #expect(!invalidates({
            _ = runtime.isPlayingAudio
            _ = runtime.isMuted
            _ = runtime.sleepTimerDeadline
            _ = runtime.isScreenSharing
            _ = runtime.loginForm
            _ = runtime.currentURL
        }, by: { store.paneDidUpdate(paneID, snapshot: loading(url, 0.5)) }))
    }

    @Test("A progress tick leaves the tab list alone")
    func progressSparesTabs() async throws {
        let store = await makeStore()
        let paneID = try #require(store.selectedTab?.focusedPaneID)
        let url = URL(string: "https://example.com")!
        store.paneDidUpdate(paneID, snapshot: loading(url, 0.1))

        #expect(!invalidates({ _ = store.tabs }, by: {
            store.paneDidUpdate(paneID, snapshot: loading(url, 0.5))
        }))
    }

    @Test("A real change still reaches its readers")
    func realChangesNotify() async throws {
        let store = await makeStore()
        let paneID = try #require(store.selectedTab?.focusedPaneID)
        let url = URL(string: "https://example.com")!
        store.paneDidUpdate(paneID, snapshot: loading(url, 0.1))
        let runtime = store.runtime(for: paneID)

        var audible = loading(url, 0.1)
        audible.isPlayingAudio = true
        #expect(invalidates({ _ = runtime.isPlayingAudio }, by: {
            store.paneDidUpdate(paneID, snapshot: audible)
        }))

        var renamed = audible
        renamed.title = "Renamed"
        #expect(invalidates({ _ = store.tabs }, by: {
            store.paneDidUpdate(paneID, snapshot: renamed)
        }))
        #expect(store.selectedTab?.focusedPane.title == "Renamed")
    }

    @Test("Progress moves in visible steps, and always lands on its ends")
    func progressIsCoalesced() async throws {
        let store = await makeStore()
        let paneID = try #require(store.selectedTab?.focusedPaneID)
        let url = URL(string: "https://example.com")!
        store.paneDidUpdate(paneID, snapshot: loading(url, 0.31))
        let runtime = store.runtime(for: paneID)

        #expect(!invalidates({ _ = runtime.estimatedProgress }, by: {
            store.paneDidUpdate(paneID, snapshot: loading(url, 0.33))
        }))
        #expect(invalidates({ _ = runtime.estimatedProgress }, by: {
            store.paneDidUpdate(paneID, snapshot: loading(url, 0.40))
        }))
        #expect(invalidates({ _ = runtime.estimatedProgress }, by: {
            store.paneDidUpdate(paneID, snapshot: loading(url, 1))
        }))
        #expect(runtime.estimatedProgress == 1)
        store.paneDidUpdate(paneID, snapshot: loading(url, 0))
        #expect(runtime.estimatedProgress == 0)
    }
}
