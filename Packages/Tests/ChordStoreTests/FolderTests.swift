import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// Sidebar folders (non-spec: user-requested).
@Suite("Folders")
@MainActor
struct FolderTests {

    private func makeStore(stored: [Tab] = []) async -> TabStore {
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: FakeTabRepository(stored: stored),
            folderRepository: InMemoryFolderRepository(),
            clock: FixedClock()
        )
        await store.restore()
        return store
    }

    @Test("Adding a folder puts it in the active Space")
    func addFolder() async {
        let store = await makeStore()
        let id = try! #require(store.addFolder(name: "Work"))
        #expect(store.activeSpaceFolders.map(\.id) == [id])
        #expect(store.activeSpaceFolders.first?.spaceID == store.activeSpaceID)
    }

    @Test("Moving a tab into a folder groups it and removes it from the loose list")
    func moveIntoFolder() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://a.example").build(),
            TabBuilder().url("https://b.example").build(),
        ])
        let tab = try! #require(store.unpinnedTabs.first)
        let folder = try! #require(store.addFolder(name: "Group"))

        store.moveTab(tab.id, toFolder: folder)

        #expect(store.tabs(inFolder: folder).map(\.id) == [tab.id])
        #expect(!store.unpinnedTabs.contains { $0.id == tab.id })
    }

    @Test("A foldered tab is exempt from the sweep")
    func folderedTabIsNotSwept() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://keep.example").build()
        ])
        let tab = try! #require(store.unpinnedTabs.first)
        let folder = try! #require(store.addFolder())
        store.moveTab(tab.id, toFolder: folder)

        store.idleWindow = .after(1)
        store.select(store.addTabForTest())  // make a different tab selected
        await store.sweepNow()

        #expect(store.tabs.contains { $0.id == tab.id }, "foldered tab survives the sweep")
    }

    @Test("Deleting a folder keeps its tabs, now loose")
    func deleteFolderKeepsTabs() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://a.example").build()
        ])
        let tab = try! #require(store.unpinnedTabs.first)
        let folder = try! #require(store.addFolder())
        store.moveTab(tab.id, toFolder: folder)

        store.deleteFolder(folder)

        #expect(store.activeSpaceFolders.isEmpty)
        #expect(store.unpinnedTabs.contains { $0.id == tab.id })
    }

    @Test("Collapsing toggles the folder's state")
    func collapse() async {
        let store = await makeStore()
        let folder = try! #require(store.addFolder())
        #expect(store.activeSpaceFolders.first?.isCollapsed == false)
        store.toggleFolderCollapsed(folder)
        #expect(store.activeSpaceFolders.first?.isCollapsed == true)
    }
}

/// A minimal in-memory folder store for the tests above.
private actor InMemoryFolderRepository: FolderRepository {
    private var saved: [Folder] = []
    func loadFolders() async throws -> [Folder] { saved }
    func saveFolders(_ folders: [Folder]) async throws { saved = folders }
}

extension TabStore {
    /// Adds a throwaway tab and returns its id, for tests that need a second,
    /// selectable tab so the tab under test is not the selected one.
    func addTabForTest() -> UUID {
        newTab(url: URL(string: "https://other.example")!)
        return selectedTabID!
    }
}
