import ChordCore
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

private actor ArcImportArchiveSpy: ArchiveRepository {
    private(set) var archived: [ArchivedTab] = []

    func archive(_ tabs: [ArchivedTab]) async throws { archived += tabs }
    func archivedTabs() async throws -> [ArchivedTab] { archived }
    func count() -> Int { archived.count }
}

private actor ArcImportFolderStore: FolderRepository {
    private let stored: [Folder]

    init(stored: [Folder]) { self.stored = stored }

    func loadFolders() async throws -> [Folder] { stored }
    func saveFolders(_ folders: [Folder]) async throws {}
}

/// The apply pass: Arc's Spaces, Pinned list and top apps land in Chord's
/// existing three tiers, and a second import changes nothing.
@Suite("Arc import apply")
@MainActor
struct ArcImportStoreTests {

    private func makeStore(
        spaces: [Space] = [],
        tabs: [Tab] = [],
        folders: [Folder] = [],
        window: WindowState? = nil,
        archive: ArcImportArchiveSpy? = nil
    ) async -> TabStore {
        let repository = FakeTabRepository(stored: tabs, spaces: spaces)
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: repository,
            spaceRepository: repository,
            archiveRepository: archive,
            folderRepository: ArcImportFolderStore(stored: folders),
            clock: FixedClock(),
            primaryWindow: window
        )
        await store.restore()
        return store
    }

    private func tab(
        _ url: String, title: String = "", path: [String] = []
    ) -> ArcImportTab {
        ArcImportTab(
            title: title, url: URL(string: url)!, folderPath: path
        )
    }

    private func plan(
        space: String = "Work",
        icon: String? = "💼",
        folders: [ArcImportFolder] = [],
        pins: [ArcImportTab] = [],
        favourites: [ArcImportTab] = []
    ) -> ArcImportPlan {
        ArcImportPlan(spaces: [
            ArcImportSpace(
                name: space,
                icon: icon,
                folders: folders,
                pinned: pins,
                favourites: favourites
            ),
        ])
    }

    @Test("Spaces, Pinned tabs, favourites and flat folders are written")
    func appliesPlan() async throws {
        let store = await makeStore()
        let workPlan = plan(
            folders: [
                ArcImportFolder(path: ["Reading"]),
                ArcImportFolder(path: ["Reading", "Deep"]),
                ArcImportFolder(path: ["Empty"]),
            ],
            pins: [
                tab("https://docs.example/start", title: "Docs"),
                tab("https://articles.example/one", title: "An Article", path: ["Reading"]),
                tab("https://deep.example/", title: "Deep Page", path: ["Reading", "Deep"]),
            ],
            favourites: [
                tab("https://mail.example/", title: "Mail"),
            ]
        )

        let result = store.importArc(workPlan, in: store.primaryWindow)

        #expect(result.spacesCreated == 1)
        #expect(result.spacesReused == 0)
        #expect(result.foldersCreated == 3)
        #expect(result.foldersReused == 0)
        #expect(result.pinsAdded == 3)
        #expect(result.pinsSkippedExisting == 0)
        #expect(result.favouritesAdded == 1)
        #expect(result.favouritesSkippedExisting == 0)
        #expect(result.didWriteAnything)

        let work = try #require(store.spaces.first { $0.name == "Work" })
        #expect(work.iconSymbol == "💼")

        let workTabs = store.tabs.filter { $0.spaceID == work.id }
        #expect(workTabs.count == 4)

        let pins = workTabs
            .filter(\.placement.isBookmarked)
            .sorted { $0.placement.order < $1.placement.order }
        #expect(pins.map(\.focusedPane.url.absoluteString) == [
            "https://docs.example/start",
            "https://articles.example/one",
            "https://deep.example/",
        ])
        #expect(pins.map(\.focusedPane.title) == ["Docs", "An Article", "Deep Page"])
        #expect(pins.allSatisfy { $0.placement.homeURL == $0.focusedPane.url })

        let reading = try #require(store.folders.first {
            $0.spaceID == work.id && $0.name == "Reading"
        })
        let deep = try #require(store.folders.first {
            $0.spaceID == work.id && $0.name == "Reading / Deep"
        })
        let empty = try #require(store.folders.first {
            $0.spaceID == work.id && $0.name == "Empty"
        })
        #expect(reading.id != deep.id)
        #expect(empty.sortIndex > deep.sortIndex)

        let article = try #require(pins.first {
            $0.focusedPane.url.host() == "articles.example"
        })
        #expect(article.folderID == reading.id)
        let deepPage = try #require(pins.first {
            $0.focusedPane.url.host() == "deep.example"
        })
        #expect(deepPage.folderID == deep.id)

        let favourite = try #require(workTabs.first { $0.placement.isPinned })
        #expect(favourite.focusedPane.url.absoluteString == "https://mail.example/")
        #expect(favourite.placement.homeURL?.absoluteString == "https://mail.example/")
        #expect(favourite.folderID == nil)
    }

    @Test("Re-importing the same plan adds nothing and creates no twins")
    func reimportIsIdempotent() async {
        let store = await makeStore()
        let workPlan = plan(
            folders: [
                ArcImportFolder(path: ["Reading"]),
                ArcImportFolder(path: ["Reading", "Deep"]),
            ],
            pins: [
                tab("https://docs.example/", path: []),
                tab("https://article.example/", path: ["Reading", "Deep"]),
            ],
            favourites: [tab("https://mail.example/")]
        )

        let first = store.importArc(workPlan, in: store.primaryWindow)
        #expect(first.spacesCreated == 1)
        #expect(first.addedCount == 3)
        let tabCount = store.tabs.count
        let folderCount = store.folders.count
        let spaceCount = store.spaces.count

        let second = store.importArc(workPlan, in: store.primaryWindow)
        #expect(second.spacesCreated == 0)
        #expect(second.spacesReused == 1)
        #expect(second.foldersCreated == 0)
        #expect(second.foldersReused == 2)
        #expect(second.pinsAdded == 0)
        #expect(second.pinsSkippedExisting == 2)
        #expect(second.favouritesAdded == 0)
        #expect(second.favouritesSkippedExisting == 1)
        #expect(!second.didWriteAnything)

        #expect(store.tabs.count == tabCount)
        #expect(store.folders.count == folderCount)
        #expect(store.spaces.count == spaceCount)
    }

    @Test("An existing Space is matched by name regardless of case")
    func reusesExistingSpace() async throws {
        let existing = Space(name: "WORK", sortIndex: 0)
        let store = await makeStore(spaces: [existing])

        let result = store.importArc(
            plan(space: "Work", pins: [tab("https://docs.example/")]),
            in: store.primaryWindow
        )

        #expect(result.spacesCreated == 0)
        #expect(result.spacesReused == 1)
        #expect(store.spaces.count == 1)
        #expect(store.spaces[0].name == "WORK")
        let imported = try #require(store.tabs.first {
            $0.focusedPane.url.absoluteString == "https://docs.example/"
        })
        #expect(imported.spaceID == existing.id)
    }

    @Test("A page already in the same Pinned folder is not added again")
    func skipsExistingEntries() async throws {
        let work = Space(name: "Work", sortIndex: 0)
        let folder = Folder(spaceID: work.id, name: "Reading", sortIndex: 0)
        let pinURL = URL(string: "https://docs.example/start")!
        let favouriteURL = URL(string: "https://mail.example/")!
        let existingPin = Tab(
            url: pinURL,
            spaceID: work.id,
            placement: .bookmarked(order: 4, homeURL: pinURL),
            now: Date(timeIntervalSince1970: 1_000)
        )
        let existingFavourite = Tab(
            url: favouriteURL,
            spaceID: work.id,
            placement: .pinned(order: 2, homeURL: favouriteURL),
            now: Date(timeIntervalSince1970: 1_000)
        )
        // Folder membership is on the tab; set it after construction because
        // the convenience initialiser has no folder parameter.
        var foldered = existingPin
        foldered.folderID = folder.id

        let store = await makeStore(
            spaces: [work], tabs: [foldered, existingFavourite], folders: [folder]
        )
        let result = store.importArc(
            plan(
                space: "Work",
                folders: [ArcImportFolder(path: ["Reading"])],
                pins: [
                    tab(pinURL.absoluteString, path: ["Reading"]),
                    tab("https://new.example/", path: ["Reading"]),
                ],
                favourites: [tab(favouriteURL.absoluteString)]
            ),
            in: store.primaryWindow
        )

        #expect(result.foldersCreated == 0)
        #expect(result.foldersReused == 1)
        #expect(result.pinsAdded == 1)
        #expect(result.pinsSkippedExisting == 1)
        #expect(result.favouritesAdded == 0)
        #expect(result.favouritesSkippedExisting == 1)
        let workTabs = store.tabs.filter { $0.spaceID == work.id }
        #expect(workTabs.count == 3)

        let added = try #require(workTabs.first {
            $0.focusedPane.url.absoluteString == "https://new.example/"
        })
        #expect(added.folderID == folder.id)
        // Dense order within the Pinned tier, after the existing pin.
        #expect(added.placement.order == 5)
    }

    @Test("Favourites already in the grid are not duplicated")
    func skipsExistingFavourites() async {
        let work = Space(name: "Work", sortIndex: 0)
        let url = URL(string: "https://mail.example/")!
        let existing = Tab(
            url: url,
            spaceID: work.id,
            placement: .pinned(order: 0, homeURL: url),
            now: Date(timeIntervalSince1970: 1_000)
        )
        let store = await makeStore(spaces: [work], tabs: [existing])

        let result = store.importArc(
            plan(space: "Work", favourites: [tab(url.absoluteString)]),
            in: store.primaryWindow
        )

        #expect(result.favouritesAdded == 0)
        #expect(result.favouritesSkippedExisting == 1)
        #expect(store.tabs.filter { $0.spaceID == work.id }.count == 1)
    }

    @Test("A private window refuses the whole plan")
    func refusesPrivateWindow() async {
        let store = await makeStore()
        let privateWindow = WindowState(isPrivate: true)
        let workPlan = plan(
            folders: [ArcImportFolder(path: ["Reading"])],
            pins: [tab("https://docs.example/")],
            favourites: [tab("https://mail.example/")]
        )

        let result = store.importArc(workPlan, in: privateWindow)

        #expect(!result.didWriteAnything)
        #expect(result.spacesCreated == 0)
        #expect(result.pinsAdded == 0)
        #expect(result.favouritesAdded == 0)
        #expect(store.tabs.allSatisfy { $0.placement.isEphemeral })
        #expect(store.folders.isEmpty)
        #expect(store.spaces.count == 1)
    }

    @Test("Folders missing from a hand-built plan are created from tab paths")
    func createsFoldersFromTabPaths() async throws {
        let store = await makeStore()
        let result = store.importArc(
            plan(pins: [tab("https://deep.example/", path: ["Parent", "Child"])]),
            in: store.primaryWindow
        )

        #expect(result.foldersCreated == 1)
        let folder = try #require(store.folders.first)
        #expect(folder.name == "Parent / Child")
        let imported = try #require(store.tabs.first {
            $0.focusedPane.url.absoluteString == "https://deep.example/"
        })
        #expect(imported.folderID == folder.id)
    }

    @Test("Importing never touches the archive")
    func leavesArchivesAlone() async {
        let archive = ArcImportArchiveSpy()
        let store = await makeStore(archive: archive)
        store.importArc(
            plan(pins: [tab("https://docs.example/")]),
            in: store.primaryWindow
        )
        let archived = await archive.count()
        #expect(archived == 0)
    }

    @Test("Top-level pins land in the Pinned section, favourites in the grid")
    func separatesTheTwoTiers() async {
        let store = await makeStore()
        store.importArc(
            plan(
                pins: [tab("https://pin.example/")],
                favourites: [tab("https://fav.example/")]
            ),
            in: store.primaryWindow
        )

        let work = store.spaces.first { $0.name == "Work" }!
        store.primaryWindow.activeSpaceID = work.id
        #expect(store.bookmarkedTabs(in: store.primaryWindow).count == 1)
        #expect(store.pinnedTabs(in: store.primaryWindow).count == 1)
        #expect(store.tabs.filter { $0.spaceID == work.id }.count == 2)
        #expect(store.tabs.first { $0.placement.isBookmarked }?.folderID == nil)
        #expect(store.tabs.first { $0.placement.isPinned }?.folderID == nil)
    }
}
