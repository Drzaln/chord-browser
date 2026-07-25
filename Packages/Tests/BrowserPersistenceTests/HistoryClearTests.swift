import BrowserCore
import Foundation
import Testing

@testable import BrowserPersistence

@Suite("History clear")
struct HistoryClearTests {
    @Test("deleteAllHistory empties the table")
    func deleteAllEmptiesHistory() async throws {
        let repo = SQLiteHistoryRepository(database: try BrowserDatabase.inMemory())
        try await repo.recordVisit(url: URL(string: "https://a.com")!, title: "A", at: Date())
        try await repo.recordVisit(url: URL(string: "https://b.com")!, title: "B", at: Date())
        #expect(try await repo.recentHistory(limit: 10).count == 2)

        try await repo.deleteAllHistory()

        #expect(try await repo.recentHistory(limit: 10).isEmpty)
    }

    @Test("deleteAllHistory on an empty table is a no-op, not an error")
    func deleteAllOnEmptyIsFine() async throws {
        let repo = SQLiteHistoryRepository(database: try BrowserDatabase.inMemory())
        try await repo.deleteAllHistory()
        #expect(try await repo.recentHistory(limit: 10).isEmpty)
    }
}
