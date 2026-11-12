import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// Bookmarks are Arc-style *Pinned* tabs and folders are the existing sidebar
/// folder tree (there is no separate bookmark database in Chord).
@Suite("Bookmark HTML import")
@MainActor
struct BookmarkImportStoreTests {

    private let fixture = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
            <DT><A HREF="https://root.example/">Root</A>
            <DT><H3>Work</H3>
            <DL><p>
                <DT><A HREF="https://work.example/">Work</A>
                <DT><H3>Dev</H3>
                <DL><p>
                    <DT><A HREF="https://dev.example/">Dev</A>
                </DL><p>
            </DL><p>
            <DT><A HREF="javascript:void(0)">Script</A>
        </DL><p>
        """

    private func makeStore() async -> (TabStore, FakeTabRepository, InMemoryFolderRepository) {
        let tabs = FakeTabRepository()
        let folders = InMemoryFolderRepository()
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: tabs,
            folderRepository: folders,
            clock: FixedClock()
        )
        await store.restore()
        return (store, tabs, folders)
    }

    private func plan() -> BookmarkImportPlan {
        NetscapeBookmarkParser.parse(html: fixture)
    }

    @Test("Importing a plan writes folders and Pinned tabs into the active Space")
    func appliesPlan() async {
        let (store, _, _) = await makeStore()
        let window = store.primaryWindow
        let plan = plan()
        let baseline = store.tabs.count

        let result = store.importBookmarks(plan, in: window)

        #expect(result.foldersCreated == 2)
        #expect(result.foldersReused == 0)
        #expect(result.entriesAdded == 3)
        #expect(result.entriesSkippedExisting == 0)
        #expect(result.parserSkipped == 1)
        #expect(store.folders(in: window).map(\.name) == ["Work", "Work / Dev"])
        #expect(store.tabs.count == baseline + 3)

        let root = store.bookmarkedTabs(in: window)
        #expect(root.map { $0.focusedPane.url.absoluteString } == ["https://root.example/"])
        #expect(root.first?.focusedPane.title == "Root")

        let workID = try! #require(store.folders(in: window).first { $0.name == "Work" }?.id)
        let workTabs = store.tabs(inFolder: workID)
        #expect(workTabs.map { $0.focusedPane.url.absoluteString } == ["https://work.example/"])
        #expect(workTabs.first?.placement.isBookmarked == true)
        #expect(workTabs.first?.placement.homeURL?.absoluteString == "https://work.example/")
        #expect(workTabs.first?.focusedPane.title == "Work")

        let devID = try! #require(
            store.folders(in: window).first { $0.name == "Work / Dev" }?.id
        )
        #expect(store.tabs(inFolder: devID).map { $0.focusedPane.url.absoluteString }
            == ["https://dev.example/"])
    }

    @Test("Re-importing the same file is a no-op")
    func reimportDoesNotDuplicate() async {
        let (store, _, _) = await makeStore()
        let window = store.primaryWindow
        let plan = plan()
        let baseline = store.tabs.count

        _ = store.importBookmarks(plan, in: window)
        let second = store.importBookmarks(plan, in: window)

        #expect(second.foldersCreated == 0)
        #expect(second.foldersReused == 2)
        #expect(second.entriesAdded == 0)
        #expect(second.entriesSkippedExisting == 3)
        #expect(store.folders(in: window).count == 2)
        #expect(store.tabs.count == baseline + 3)
    }

    @Test("A bookmark already in the target folder is not added again")
    func existingBookmarkIsSkipped() async {
        let (store, _, _) = await makeStore()
        let window = store.primaryWindow
        let baseline = store.tabs.count
        let folderID = try! #require(store.addFolder(name: "Work"))
        let tabID = store.newTab(url: URL(string: "https://work.example/")!, in: window)
        store.setBookmarked(true, tabID: tabID)
        store.moveTab(tabID, toFolder: folderID)

        let result = store.importBookmarks(plan(), in: window)

        #expect(result.entriesSkippedExisting == 1)
        #expect(result.entriesAdded == 2)
        #expect(store.tabs(inFolder: folderID).map { $0.focusedPane.url.absoluteString }
            == ["https://work.example/"])
        #expect(store.tabs.count == baseline + 3)
    }

    @Test("Import leaves the window's selection alone")
    func selectionIsUnchanged() async {
        let (store, _, _) = await makeStore()
        let window = store.primaryWindow
        let tabID = store.newTab(url: URL(string: "https://open.example/")!, in: window)
        #expect(window.selectedTabID == tabID)

        _ = store.importBookmarks(plan(), in: window)

        #expect(window.selectedTabID == tabID)
    }

    /// Acceptance test: export what this profile now holds, import that into an
    /// empty profile, and compare the two trees. The test doubles as the
    /// exporter Chord does not otherwise ship yet.
    @Test("Export → import into an empty profile reproduces the tree")
    func roundTrip() async throws {
        let (firstStore, _, _) = await makeStore()
        let firstWindow = firstStore.primaryWindow
        _ = firstStore.importBookmarks(plan(), in: firstWindow)

        let exported = exportBookmarks(from: firstStore, in: firstWindow)
        let reparsed = NetscapeBookmarkParser.parse(html: exported)
        let (secondStore, _, _) = await makeStore()
        let secondWindow = secondStore.primaryWindow
        let result = secondStore.importBookmarks(reparsed, in: secondWindow)

        #expect(result.entriesAdded == 3)
        #expect(result.parserSkipped == 0)
        #expect(
            secondStore.folders(in: secondWindow).map(\.name)
                == firstStore.folders(in: firstWindow).map(\.name)
        )
        #expect(
            secondStore.bookmarkedTabs(in: secondWindow)
                .map { $0.focusedPane.url.absoluteString }
                == firstStore.bookmarkedTabs(in: firstWindow)
                    .map { $0.focusedPane.url.absoluteString }
        )

        for folder in firstStore.folders(in: firstWindow) {
            let secondFolderID = try #require(
                secondStore.folders(in: secondWindow).first { $0.name == folder.name }?.id
            )
            let firstTabs = firstStore.tabs(inFolder: folder.id)
            let secondTabs = secondStore.tabs(inFolder: secondFolderID)
            #expect(
                secondTabs.map { $0.focusedPane.url.absoluteString }
                    == firstTabs.map { $0.focusedPane.url.absoluteString }
            )
            #expect(
                secondTabs.map(\.focusedPane.title) == firstTabs.map(\.focusedPane.title)
            )
        }
    }

    // MARK: - Test-only exporter

    /// The Netscape format Chord would write if it had an export feature.
    private func exportBookmarks(from store: TabStore, in window: WindowState) -> String {
        var out = "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n"

        for tab in store.bookmarkedTabs(in: window) {
            out += entryHTML(tab)
        }
        for folder in store.folders(in: window) {
            out += "<DT><H3>\(escape(folder.name))</H3>\n<DL><p>\n"
            for tab in store.tabs(inFolder: folder.id) {
                out += entryHTML(tab)
            }
            out += "</DL><p>\n"
        }

        out += "</DL><p>"
        return out
    }

    private func entryHTML(_ tab: Tab) -> String {
        let url = escape(tab.focusedPane.url.absoluteString)
        let title = escape(tab.focusedPane.title)
        return "<DT><A HREF=\"\(url)\">\(title)</A>\n"
    }

    private func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private actor InMemoryFolderRepository: FolderRepository {
    private var saved: [Folder] = []

    func loadFolders() async throws -> [Folder] { saved }
    func saveFolders(_ folders: [Folder]) async throws { saved = folders }
}
