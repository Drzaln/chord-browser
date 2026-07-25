import BrowserCore
import Foundation
import Testing

@testable import BrowserPersistence

@Suite("History storage")
struct HistoryClearTests {
    private let spaceA = UUID()
    private let spaceB = UUID()

    @Test("deleteAllHistory empties the table across every Space")
    func deleteAllEmptiesHistory() async throws {
        let repo = SQLiteHistoryRepository(database: try BrowserDatabase.inMemory())
        try await repo.recordVisit(url: URL(string: "https://a.com")!, title: "A", spaceID: spaceA, at: Date())
        try await repo.recordVisit(url: URL(string: "https://b.com")!, title: "B", spaceID: spaceB, at: Date())
        #expect(try await repo.recentHistory(inSpace: spaceA, limit: 10).count == 1)

        try await repo.deleteAllHistory()

        #expect(try await repo.recentHistory(inSpace: spaceA, limit: 10).isEmpty)
        #expect(try await repo.recentHistory(inSpace: spaceB, limit: 10).isEmpty)
    }

    @Test("Visits are scoped to their Space")
    func visitsAreScopedPerSpace() async throws {
        let repo = SQLiteHistoryRepository(database: try BrowserDatabase.inMemory())
        try await repo.recordVisit(url: URL(string: "https://shared.com")!, title: "A-side", spaceID: spaceA, at: Date())
        try await repo.recordVisit(url: URL(string: "https://shared.com")!, title: "B-side", spaceID: spaceB, at: Date())

        let a = try await repo.recentHistory(inSpace: spaceA, limit: 10)
        let b = try await repo.recentHistory(inSpace: spaceB, limit: 10)
        #expect(a.map(\.title) == ["A-side"])
        #expect(b.map(\.title) == ["B-side"])
    }

    @Test("A revisit in the same Space is an upsert, not a second row")
    func revisitUpserts() async throws {
        let repo = SQLiteHistoryRepository(database: try BrowserDatabase.inMemory())
        let url = URL(string: "https://x.com")!
        try await repo.recordVisit(url: url, title: "X", spaceID: spaceA, at: Date())
        try await repo.recordVisit(url: url, title: "X", spaceID: spaceA, at: Date())

        let rows = try await repo.recentHistory(inSpace: spaceA, limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first?.visitCount == 2)
    }

    @Test("deleteAllHistory(inSpace:) clears only that Space")
    func deleteAllInSpaceIsScoped() async throws {
        let repo = SQLiteHistoryRepository(database: try BrowserDatabase.inMemory())
        try await repo.recordVisit(url: URL(string: "https://a.com")!, title: "A", spaceID: spaceA, at: Date())
        try await repo.recordVisit(url: URL(string: "https://b.com")!, title: "B", spaceID: spaceB, at: Date())

        try await repo.deleteAllHistory(inSpace: spaceA)

        #expect(try await repo.recentHistory(inSpace: spaceA, limit: 10).isEmpty)
        #expect(try await repo.recentHistory(inSpace: spaceB, limit: 10).count == 1)
    }

    @Test("deleteHistory removes only the named entry ids")
    func deleteSelectedIDs() async throws {
        let repo = SQLiteHistoryRepository(database: try BrowserDatabase.inMemory())
        try await repo.recordVisit(url: URL(string: "https://a.com")!, title: "A", spaceID: spaceA, at: Date())
        try await repo.recordVisit(url: URL(string: "https://b.com")!, title: "B", spaceID: spaceA, at: Date())
        try await repo.recordVisit(url: URL(string: "https://c.com")!, title: "C", spaceID: spaceA, at: Date())

        let all = try await repo.recentHistory(inSpace: spaceA, limit: 10)
        let bID = try #require(all.first { $0.url.absoluteString == "https://b.com" }).id

        try await repo.deleteHistory(ids: [bID])

        let remaining = try await repo.recentHistory(inSpace: spaceA, limit: 10)
            .map { $0.url.absoluteString }
        #expect(Set(remaining) == ["https://a.com", "https://c.com"])
    }

    @Test("deleteHistory with an empty list is a no-op")
    func deleteNoneIsFine() async throws {
        let repo = SQLiteHistoryRepository(database: try BrowserDatabase.inMemory())
        try await repo.recordVisit(url: URL(string: "https://a.com")!, title: "A", spaceID: spaceA, at: Date())
        try await repo.deleteHistory(ids: [])
        #expect(try await repo.recentHistory(inSpace: spaceA, limit: 10).count == 1)
    }
}
