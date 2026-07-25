import BrowserCore
import BrowserEngine
import BrowserTestSupport
import Foundation
import Testing

@testable import BrowserStore

/// A history repository that records whether `deleteAllHistory` was called.
private actor SpyHistory: HistoryRepository {
    private(set) var deletedCount = 0
    func recordVisit(url: URL, title: String, spaceID: UUID, at date: Date) async throws {}
    func recentHistory(inSpace spaceID: UUID, limit: Int) async throws -> [HistoryEntry] { [] }
    func deleteAllHistory() async throws { deletedCount += 1 }
}

@Suite("Clear browsing data")
@MainActor
struct ClearBrowsingDataTests {
    private func makeStore(spaces: [Space])
        -> (TabStore, FakeWebEngine, SpyHistory)
    {
        let engine = FakeWebEngine()
        let repository = FakeTabRepository(stored: [], spaces: spaces)
        let history = SpyHistory()
        let store = TabStore(
            engine: engine,
            repository: repository,
            spaceRepository: repository,
            historyRepository: history,
            clock: FixedClock()
        )
        return (store, engine, history)
    }

    @Test("Website data is cleared across every Space; history is not touched")
    func cacheAndCookiesFanOutToAllSpaces() async {
        let a = Space(name: "A", sortIndex: 0)
        let b = Space(name: "B", sortIndex: 1)
        let (store, engine, history) = makeStore(spaces: [a, b])
        await store.restore()

        await store.clearBrowsingData([.cache, .cookies])

        #expect(engine.clearedData.count == 1)
        let call = engine.clearedData[0]
        #expect(call.types == [.cache, .cookies])
        #expect(Set(call.spaceIDs) == Set(store.spaces.map(\.id)))
        #expect(await history.deletedCount == 0)  // history not selected
    }

    @Test("History-only clears history and never calls the engine")
    func historyOnlySkipsEngine() async {
        let (store, engine, history) = makeStore(spaces: [Space(name: "A", sortIndex: 0)])
        await store.restore()

        await store.clearBrowsingData(.history)

        #expect(engine.clearedData.isEmpty)  // no website types selected
        #expect(await history.deletedCount == 1)
    }

    @Test("Clear-all clears both website data and history")
    func clearAllHitsBoth() async {
        let (store, engine, history) = makeStore(spaces: [Space(name: "A", sortIndex: 0)])
        await store.restore()

        await store.clearBrowsingData(.all)

        #expect(engine.clearedData.count == 1)
        #expect(!engine.clearedData[0].types.contains(.history))  // history stripped before engine
        #expect(await history.deletedCount == 1)
    }
}
