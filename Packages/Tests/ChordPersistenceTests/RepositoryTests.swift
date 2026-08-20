import ChordCore
import ChordTestSupport
import Foundation
import Testing

@testable import ChordPersistence

@Suite("SQLite tab repository")
struct RepositoryTests {

    private func makeRepository() throws -> SQLiteTabRepository {
        SQLiteTabRepository(database: try ChordDatabase.inMemory())
    }

    @Test("Saved tabs come back identical")
    func roundTrip() async throws {
        let repository = try makeRepository()
        let tabs = [
            TabBuilder().url("https://a.example").title("A").pinned(order: 0).build(),
            TabBuilder().url("https://b.example").title("B").ephemeral(order: 1).build(),
            TabBuilder().url("https://c.example").title("C")
                .bookmarked(order: 2, homeURL: "https://c.example/home").build(),
        ]

        try await repository.save(tabs)
        let loaded = try await repository.loadAll()

        #expect(loaded.count == 3)
        #expect(loaded.map(\.id) == tabs.map(\.id))
        #expect(loaded.map(\.displayTitle) == ["A", "B", "C"])
        #expect(loaded[0].placement == .pinned(order: 0, homeURL: URL(string: "https://a.example")!))
        #expect(loaded[1].placement == .ephemeral(order: 1))
        #expect(
            loaded[2].placement == .bookmarked(
                order: 2, homeURL: URL(string: "https://c.example/home")!
            )
        )
    }

    @Test("Pane order is preserved across a save")
    func paneOrderPreserved() async throws {
        let repository = try makeRepository()
        let tab = TabBuilder()
            .url("https://first.example")
            .extraPane(url: "https://second.example")
            .extraPane(url: "https://third.example")
            .build()

        try await repository.save([tab])
        let loaded = try await repository.loadAll()

        #expect(loaded[0].panes.map { $0.url.host() } == [
            "first.example", "second.example", "third.example",
        ])
    }

    @Test("A save replaces the previous set rather than appending")
    func saveReplaces() async throws {
        let repository = try makeRepository()
        try await repository.save([TabBuilder().url("https://a.example").build()])
        try await repository.save([TabBuilder().url("https://b.example").build()])

        let loaded = try await repository.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].panes[0].url.host() == "b.example")
    }

    @Test("Favicon bytes survive the round-trip")
    func faviconRoundTrip() async throws {
        let repository = try makeRepository()
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try await repository.save([TabBuilder().favicon(bytes).build()])

        let loaded = try await repository.loadAll()
        #expect(loaded[0].panes[0].faviconData == bytes)
    }

    @Test("interactionState is stored out-of-line and not loaded with the tab")
    func interactionStateIsSeparate() async throws {
        let repository = try makeRepository()
        let tab = TabBuilder().build()
        let paneID = tab.panes[0].id
        try await repository.save([tab])

        let blob = Data(repeating: 0xAB, count: 4096)
        try await repository.saveInteractionState(blob, paneID: paneID)

        // A plain tab load must not carry the blob (6.5).
        let loaded = try await repository.loadAll()
        #expect(loaded[0].panes[0].interactionState == nil)

        // It is there when asked for explicitly.
        #expect(try await repository.loadInteractionState(paneID: paneID) == blob)
    }

    @Test("Clearing interactionState removes it")
    func interactionStateCleared() async throws {
        let repository = try makeRepository()
        let paneID = UUID()
        try await repository.saveInteractionState(Data([0x01]), paneID: paneID)
        try await repository.saveInteractionState(nil, paneID: paneID)

        #expect(try await repository.loadInteractionState(paneID: paneID) == nil)
    }

    @Test("An empty database loads as an empty list, not an error")
    func emptyLoads() async throws {
        let repository = try makeRepository()
        #expect(try await repository.loadAll().isEmpty)
    }
}
