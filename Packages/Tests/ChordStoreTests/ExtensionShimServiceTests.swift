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
        return (
            ExtensionShimService(store: store, downloads: downloads, bookmarks: bookmarks),
            store, engine, root
        )
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
