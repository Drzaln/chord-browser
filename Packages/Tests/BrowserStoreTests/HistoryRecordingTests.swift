import BrowserCore
import BrowserEngine
import BrowserTestSupport
import Foundation
import Testing

@testable import BrowserStore

/// History recording from the engine's snapshot stream. The engine publishes a
/// fresh snapshot per KVO change, so the title and the `isLoading=false`
/// transition usually arrive in *separate* snapshots — the case that used to
/// slip through and leave history empty.
@Suite("History recording")
@MainActor
struct HistoryRecordingTests {

    /// Captures every recorded visit so the test can assert on them.
    private actor SpyHistory: HistoryRepository {
        private(set) var visits: [(url: URL, title: String, spaceID: UUID)] = []
        func recordVisit(url: URL, title: String, spaceID: UUID, at date: Date) async throws {
            visits.append((url, title, spaceID))
        }
        func recentHistory(inSpace spaceID: UUID, limit: Int) async throws -> [HistoryEntry] { [] }
        func deleteAllHistory() async throws {}
        func count() -> Int { visits.count }
        func snapshot() -> [(url: URL, title: String, spaceID: UUID)] { visits }
    }

    private func makeStore(_ history: SpyHistory) async -> TabStore {
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: FakeTabRepository(stored: [
                TabBuilder().url("https://example.com").build()
            ]),
            historyRepository: history,
            clock: FixedClock()
        )
        await store.restore()
        return store
    }

    /// Polls the async spy, since `recordVisit` is fired from a detached Task.
    private func waitForVisits(_ history: SpyHistory, atLeast count: Int) async -> [(url: URL, title: String, spaceID: UUID)] {
        for _ in 0..<50 {
            let visits = await history.snapshot()
            if visits.count >= count { return visits }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await history.snapshot()
    }

    @Test("A visit is recorded when title and load-finished arrive in separate snapshots")
    func recordsAcrossSeparateSnapshots() async {
        let history = SpyHistory()
        let store = await makeStore(history)
        let paneID = try! #require(store.selectedTab?.focusedPaneID)
        let url = URL(string: "https://news.example/story")!

        // The real ordering: url (loading) → title (still loading) → idle.
        store.paneDidUpdate(paneID, snapshot: PaneSnapshot(url: url, isLoading: true))
        store.paneDidUpdate(paneID, snapshot: PaneSnapshot(url: url, title: "Story", isLoading: true))
        store.paneDidUpdate(paneID, snapshot: PaneSnapshot(url: url, title: "Story", isLoading: false))

        let visits = await waitForVisits(history, atLeast: 1)
        #expect(visits.count == 1)
        #expect(visits.first?.url == url)
        #expect(visits.first?.title == "Story")
        // Recorded against the tab's Space, so history stays per-Space.
        #expect(visits.first?.spaceID == store.selectedTab?.spaceID)
    }

    @Test("A title that lands after load-finished is still recorded")
    func recordsTitleAfterLoad() async {
        let history = SpyHistory()
        let store = await makeStore(history)
        let paneID = try! #require(store.selectedTab?.focusedPaneID)
        let url = URL(string: "https://late.example/")!

        store.paneDidUpdate(paneID, snapshot: PaneSnapshot(url: url, isLoading: true))
        store.paneDidUpdate(paneID, snapshot: PaneSnapshot(url: url, isLoading: false))
        // Title arrives only after loading finished.
        store.paneDidUpdate(paneID, snapshot: PaneSnapshot(url: url, title: "Late", isLoading: false))

        let visits = await waitForVisits(history, atLeast: 1)
        #expect(visits.map(\.title) == ["Late"])
    }

    @Test("Steady-state idle snapshots do not re-record the same page")
    func doesNotDuplicate() async {
        let history = SpyHistory()
        let store = await makeStore(history)
        let paneID = try! #require(store.selectedTab?.focusedPaneID)
        let url = URL(string: "https://once.example/")!

        store.paneDidUpdate(paneID, snapshot: PaneSnapshot(url: url, title: "Once", isLoading: true))
        store.paneDidUpdate(paneID, snapshot: PaneSnapshot(url: url, title: "Once", isLoading: false))
        // Further idle snapshots (progress settling, focus) must not re-record.
        store.paneDidUpdate(paneID, snapshot: PaneSnapshot(url: url, title: "Once", isLoading: false))
        store.paneDidUpdate(paneID, snapshot: PaneSnapshot(url: url, title: "Once", isLoading: false))

        _ = await waitForVisits(history, atLeast: 1)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await history.count() == 1)
    }

    @Test("A non-web scheme is never recorded")
    func skipsNonWebSchemes() async {
        let history = SpyHistory()
        let store = await makeStore(history)
        let paneID = try! #require(store.selectedTab?.focusedPaneID)

        store.paneDidUpdate(
            paneID,
            snapshot: PaneSnapshot(url: URL(string: "about:blank")!, title: "Blank", isLoading: false)
        )

        try? await Task.sleep(for: .milliseconds(50))
        #expect(await history.count() == 0)
    }
}
