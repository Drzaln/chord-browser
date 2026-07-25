import BrowserCore
import Foundation
import Testing

@testable import BrowserPersistence

@Suite("Folder persistence")
struct FolderPersistenceTests {

    @Test("Folders round-trip through save and load")
    func foldersRoundTrip() async throws {
        let repo = SQLiteTabRepository(database: try BrowserDatabase.inMemory())
        // The folder table has a foreign key to space, so the Space must exist.
        let space = Space(name: "S", sortIndex: 0)
        try await repo.saveSpaces([space])
        let folders = [
            Folder(spaceID: space.id, name: "Work", sortIndex: 0),
            Folder(spaceID: space.id, name: "Reading", sortIndex: 1, isCollapsed: true),
        ]

        try await repo.saveFolders(folders)
        let loaded = try await repo.loadFolders()

        #expect(loaded.map(\.name) == ["Work", "Reading"])
        #expect(loaded.last?.isCollapsed == true)
    }

    @Test("A tab's folderId round-trips")
    func tabFolderIDRoundTrips() async throws {
        let repo = SQLiteTabRepository(database: try BrowserDatabase.inMemory())
        let folderID = UUID()
        let tab = Tab(
            url: URL(string: "https://a.example")!,
            spaceID: UUID(),
            placement: .ephemeral(order: 0),
            now: Date()
        )
        var foldered = tab
        foldered.folderID = folderID

        try await repo.save([foldered])
        let loaded = try await repo.loadAll()

        #expect(loaded.first?.folderID == folderID)
    }

    @Test("A tab with no folder loads as nil, not a bad UUID")
    func looseTabHasNilFolder() async throws {
        let repo = SQLiteTabRepository(database: try BrowserDatabase.inMemory())
        let tab = Tab(
            url: URL(string: "https://a.example")!,
            spaceID: UUID(),
            placement: .ephemeral(order: 0),
            now: Date()
        )

        try await repo.save([tab])
        let loaded = try await repo.loadAll()

        #expect(loaded.first?.folderID == nil)
    }
}
