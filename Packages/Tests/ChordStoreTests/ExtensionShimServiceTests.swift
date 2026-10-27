import ChordCore
import ChordEngine
import ChordExtensions
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// M9: the Store-side answers for the full Chrome shim.
@MainActor
struct ExtensionShimServiceTests {
    private let context = ExtensionShimContext(
        identifier: String(repeating: "a", count: 32),
        spaceID: TabBuilder.defaultSpaceID
    )

    private func makeService() async throws -> (
        ExtensionShimService, TabStore, FakeWebEngine, URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "chord-shim-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = FakeTabRepository(
            stored: [TabBuilder().url("https://example.com/").build()],
            spaces: [TabBuilder.defaultSpace()]
        )
        let engine = FakeWebEngine()
        let store = TabStore(
            engine: engine, repository: repository, spaceRepository: repository,
            clock: FixedClock()
        )
        await store.restore()
        let downloads = DownloadsStore(
            coordinator: DownloadCoordinator(directory: root.appending(path: "Downloads"))
        )
        let bookmarks = BookmarksStore(fileURL: root.appending(path: "bookmarks.json"))
        let readingList = ReadingListStore(fileURL: root.appending(path: "reading-list.json"))
        return (
            ExtensionShimService(
                store: store, downloads: downloads, bookmarks: bookmarks,
                readingList: readingList
            ),
            store, engine, root
        )
    }

    @Test func downloadsDownloadRefusesNonWebAddresses() async throws {
        let (service, _, _, root) = try await makeService()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await service.answer(
                "downloads.download", args: [["url": "ftp://example.com/file"]],
                context: context
            )
            Issue.record("an ftp download should be refused")
        } catch {
            #expect(String(describing: error).contains("downloadable"))
        }
        let empty = try await service.answer(
            "downloads.search", args: [[]], context: context
        ) as? [[String: Any]]
        #expect(empty?.isEmpty == true)
    }

    @Test func readingListAddsQueriesAndUpdates() async throws {
        let (service, _, _, root) = try await makeService()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await service.answer(
            "readingList.addEntry",
            args: [["url": "https://example.com/read", "title": "Read me"]],
            context: context
        )
        let list = try await service.answer(
            "readingList.query", args: [[:]], context: context
        ) as? [[String: Any]]
        let entry = try #require(list?.first)
        #expect(entry["url"] as? String == "https://example.com/read")
        #expect(entry["title"] as? String == "Read me")
        #expect(entry["hasBeenRead"] as? Bool == false)
        #expect((entry["creationTime"] as? Double ?? 0) > 0)

        _ = try await service.answer(
            "readingList.updateEntry",
            args: [["url": "https://example.com/read", "hasBeenRead": true]],
            context: context
        )
        let read = try await service.answer(
            "readingList.query", args: [["hasBeenRead": true]], context: context
        ) as? [[String: Any]]
        #expect(read?.count == 1)
    }

    @Test func bookmarksRoundTripThroughTheChromeShape() async throws {
        let (service, _, _, root) = try await makeService()
        defer { try? FileManager.default.removeItem(at: root) }

        let created = try await service.answer(
            "bookmarks.create",
            args: [["title": "Chord", "url": "https://chord.example/", "parentId": "1"]],
            context: context
        ) as? [String: Any]
        #expect(created?["title"] as? String == "Chord")

        let tree = try await service.answer(
            "bookmarks.getTree", args: [], context: context
        ) as? [[String: Any]]
        let rootNode = try #require(tree?.first)
        #expect(rootNode["id"] as? String == "0")
        let children = rootNode["children"] as? [[String: Any]]
        #expect(children?.count == 2)
        let bar = try #require(children?.first)
        let entries = bar["children"] as? [[String: Any]]
        #expect(entries?.contains { $0["url"] as? String == "https://chord.example/" } == true)
    }

    @Test func foldersAreExposedAsTabGroups() async throws {
        let (service, store, _, root) = try await makeService()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = store.addFolder(name: "Work")
        let groups = try await service.answer(
            "tabGroups.query", args: [[:]], context: context
        ) as? [[String: Any]]
        #expect(groups?.first?["title"] as? String == "Work")
        #expect(groups?.first?["id"] as? Int == 1)
        #expect(groups?.first?["color"] as? String == "grey")
    }

    @Test func sidePanelOpenPrefersTheDockedPanel() async throws {
        let (service, _, _, root) = try await makeService()
        defer { try? FileManager.default.removeItem(at: root) }

        var opened: URL?
        service.onSidePanel = { _, url in opened = url }
        _ = try await service.answer(
            "sidePanel.setOptions", args: [["path": "panel.html", "enabled": true]],
            context: context
        )
        _ = try await service.answer("sidePanel.open", args: [], context: context)
        #expect(opened?.path == "/panel.html")
        #expect(opened?.host() == context.identifier)
    }

    @Test func sidePanelOpenFallsBackToATab() async throws {
        let (service, store, _, root) = try await makeService()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await service.answer(
            "sidePanel.setOptions",
            args: [["path": "panel.html", "enabled": true]], context: context
        )
        let before = store.tabs.count
        _ = try await service.answer("sidePanel.open", args: [], context: context)
        #expect(store.tabs.count == before + 1)
        #expect(store.tabs.last?.focusedPane.url.absoluteString
            == "chrome-extension://\(context.identifier)/panel.html")
    }

    @Test func searchQueryOpensTheConfiguredEngine() async throws {
        let (service, store, _, root) = try await makeService()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await service.answer(
            "search.query", args: [["text": "swift webkit"]], context: context
        )
        #expect(store.tabs.count == 2)
        #expect(store.tabs.last?.focusedPane.url.absoluteString.contains("swift") == true)
    }

    @Test func unknownAPIIsRefused() async throws {
        let (service, _, _, root) = try await makeService()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: ExtensionShimService.Unsupported.self) {
            try await service.answer("bookmarks.nope", args: [], context: context)
        }
    }
}
