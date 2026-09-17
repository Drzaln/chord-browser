import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// The whole command bar is scoped to the window's active Space (4.4): its open
/// tabs, its history, and its archive — nothing from another Space leaks in, so
/// typing never switches Space as a side effect.
@Suite("Command bar Space scoping")
@MainActor
struct CommandBarScopingTests {

    /// History keyed by Space, so a query can prove which Space was read.
    private actor StubHistory: HistoryRepository {
        private let entries: [UUID: [HistoryEntry]]
        init(_ entries: [UUID: [HistoryEntry]] = [:]) { self.entries = entries }
        func recordVisit(url: URL, title: String, spaceID: UUID, at date: Date) async throws {}
        func recentHistory(inSpace spaceID: UUID, limit: Int) async throws -> [HistoryEntry] {
            Array((entries[spaceID] ?? []).prefix(limit))
        }
        func deleteAllHistory() async throws {}
    }

    private actor StubArchive: ArchiveRepository {
        private let tabs: [ArchivedTab]
        init(_ tabs: [ArchivedTab] = []) { self.tabs = tabs }
        func archive(_ tabs: [ArchivedTab]) async throws {}
        func archivedTabs() async throws -> [ArchivedTab] { tabs }
    }

    private func makeStore(
        tabs: [Tab] = [],
        spaces: [Space] = [],
        history: HistoryRepository = StubHistory(),
        archive: ArchiveRepository? = nil
    ) async -> TabStore {
        let repository = FakeTabRepository(stored: tabs, spaces: spaces)
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: repository,
            spaceRepository: repository,
            historyRepository: history,
            archiveRepository: archive,
            clock: FixedClock()
        )
        await store.restore()
        return store
    }

    private func twoSpaces() -> (Space, Space) {
        (Space(name: "Personal", sortIndex: 0), Space(name: "Work", sortIndex: 1))
    }

    @Test("Only the active Space's open tabs are offered")
    func openTabsAreScopedToTheActiveSpace() async {
        let (personal, work) = twoSpaces()
        let store = await makeStore(
            tabs: [
                TabBuilder().url("https://youtube.com").title("YouTube").space(personal.id).build(),
                TabBuilder().url("https://youtube.com").title("YouTube Work").space(work.id).build(),
            ],
            spaces: [personal, work]
        )

        store.selectSpace(personal.id)
        #expect(store.suggestions(for: "youtube").filter(\.isOpenTab).map(\.title) == ["YouTube"])

        store.selectSpace(work.id)
        #expect(
            store.suggestions(for: "youtube").filter(\.isOpenTab).map(\.title) == ["YouTube Work"]
        )
    }

    @Test("An empty query lists only the active Space's tabs")
    func emptyQueryIsScopedToTheActiveSpace() async {
        let (personal, work) = twoSpaces()
        let store = await makeStore(
            tabs: [
                TabBuilder().url("https://p.example").title("Personal").space(personal.id).build(),
                TabBuilder().url("https://w.example").title("Work").space(work.id).build(),
            ],
            spaces: [personal, work]
        )

        store.selectSpace(work.id)
        let titles = store.suggestions(for: "").filter(\.isOpenTab).map(\.title)
        #expect(titles == ["Work"])
    }

    @Test("History is read for the window's active Space")
    func historyIsScopedToTheActiveSpace() async {
        let (personal, work) = twoSpaces()
        let history = StubHistory([
            personal.id: [
                HistoryEntry(
                    url: URL(string: "https://personal.example")!,
                    title: "Personal Page",
                    lastVisitedAt: Date()
                )
            ],
            work.id: [
                HistoryEntry(
                    url: URL(string: "https://work.example")!,
                    title: "Work Page",
                    lastVisitedAt: Date()
                )
            ],
        ])
        let store = await makeStore(spaces: [personal, work], history: history)

        store.selectSpace(personal.id)
        await store.prepareCommandBar(in: store.primaryWindow)
        #expect(store.suggestions(for: "page").map(\.title).contains("Personal Page"))
        #expect(!store.suggestions(for: "page").map(\.title).contains("Work Page"))

        store.selectSpace(work.id)
        await store.prepareCommandBar(in: store.primaryWindow)
        #expect(store.suggestions(for: "page").map(\.title).contains("Work Page"))
        #expect(!store.suggestions(for: "page").map(\.title).contains("Personal Page"))
    }

    @Test("Archived tabs from another Space are not offered")
    func archiveIsScopedToTheActiveSpace() async {
        let (personal, work) = twoSpaces()
        let archive = StubArchive([
            ArchivedTab(
                url: URL(string: "https://closed.example/personal")!,
                title: "Closed Personal",
                spaceID: personal.id,
                archivedAt: Date()
            ),
            ArchivedTab(
                url: URL(string: "https://closed.example/work")!,
                title: "Closed Work",
                spaceID: work.id,
                archivedAt: Date()
            ),
        ])
        let store = await makeStore(spaces: [personal, work], archive: archive)

        store.selectSpace(personal.id)
        await store.prepareCommandBar(in: store.primaryWindow)
        #expect(store.suggestions(for: "closed").map(\.title).contains("Closed Personal"))
        #expect(!store.suggestions(for: "closed").map(\.title).contains("Closed Work"))
    }
}
