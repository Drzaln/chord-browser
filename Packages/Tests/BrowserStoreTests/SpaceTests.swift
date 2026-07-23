import BrowserCore
import BrowserEngine
import BrowserStore
import BrowserTestSupport
import Foundation
import Testing

@Suite("Spaces")
@MainActor
struct SpaceStoreTests {

    private func makeStore(
        tabs: [Tab] = [],
        spaces: [Space] = []
    ) -> (TabStore, FakeWebEngine, FakeTabRepository) {
        let engine = FakeWebEngine()
        let repository = FakeTabRepository(stored: tabs, spaces: spaces)
        let store = TabStore(
            engine: engine,
            repository: repository,
            spaceRepository: repository,
            clock: FixedClock()
        )
        return (store, engine, repository)
    }

    private func twoSpaces() -> (Space, Space) {
        (Space(name: "Personal", sortIndex: 0), Space(name: "Work", sortIndex: 1))
    }

    @Test("A fresh profile gets one default Space")
    func freshProfileHasOneSpace() async {
        let (store, _, repository) = makeStore()
        await store.restore()

        #expect(store.spaces.count == 1)
        #expect(store.activeSpace?.id == store.spaces[0].id)
        #expect(await repository.storedSpaces.count == 1)  // persisted, not just in memory
    }

    @Test("Each Space gets its own data store identifier")
    func spacesHaveDistinctDataStores() async {
        let (store, _, _) = makeStore()
        await store.restore()
        store.addSpace(name: "Work")

        let identifiers = Set(store.spaces.map(\.dataStoreID))
        #expect(identifiers.count == store.spaces.count)
    }

    @Test("The sidebar shows only the active Space's tabs")
    func visibleTabsArePartitioned() async {
        let (personal, work) = twoSpaces()
        let (store, _, _) = makeStore(
            tabs: [
                TabBuilder().url("https://p1.example").space(personal.id).build(),
                TabBuilder().url("https://p2.example").space(personal.id).build(),
                TabBuilder().url("https://w1.example").space(work.id).build(),
            ],
            spaces: [personal, work]
        )
        await store.restore()

        #expect(store.tabs.count == 3)
        #expect(store.visibleTabs.count == 2)

        store.selectSpace(work.id)
        #expect(store.visibleTabs.count == 1)
        #expect(store.visibleTabs[0].panes[0].url.host() == "w1.example")
    }

    @Test("A pane's web view is built against its own Space, not the active one")
    func surfaceUsesOwningSpace() async {
        let (personal, work) = twoSpaces()
        let workTab = TabBuilder().url("https://w.example").space(work.id).build()
        let (store, engine, _) = makeStore(tabs: [workTab], spaces: [personal, work])
        await store.restore()

        // Active Space is Personal; the tab belongs to Work.
        _ = store.surface(for: workTab)

        // Getting this wrong would hand the page another Space's cookies.
        #expect(engine.spaceForPane[workTab.focusedPaneID] == work.id)
    }

    @Test("Switching Space remembers where you were")
    func switchRestoresSelection() async {
        let (personal, work) = twoSpaces()
        let (store, _, _) = makeStore(
            tabs: [
                TabBuilder().url("https://p1.example").space(personal.id).ephemeral(order: 0)
                    .build(),
                TabBuilder().url("https://p2.example").space(personal.id).ephemeral(order: 1)
                    .build(),
                TabBuilder().url("https://w1.example").space(work.id).build(),
            ],
            spaces: [personal, work]
        )
        await store.restore()

        let chosen = store.visibleTabs[0].id
        store.select(chosen)
        store.selectSpace(work.id)
        store.selectSpace(personal.id)

        #expect(store.selectedTabID == chosen)
    }

    @Test("Switching to an empty Space opens a tab in it")
    func emptySpaceGetsATab() async {
        let (personal, work) = twoSpaces()
        let (store, _, _) = makeStore(
            tabs: [TabBuilder().space(personal.id).build()],
            spaces: [personal, work]
        )
        await store.restore()

        store.selectSpace(work.id)

        #expect(store.visibleTabs.count == 1)
        #expect(store.visibleTabs[0].spaceID == work.id)
    }

    @Test("A new tab lands in the active Space")
    func newTabJoinsActiveSpace() async {
        let (personal, work) = twoSpaces()
        let (store, _, _) = makeStore(spaces: [personal, work])
        await store.restore()
        store.selectSpace(work.id)

        store.newTab(url: URL(string: "https://new.example")!)

        #expect(store.selectedTab?.spaceID == work.id)
    }

    @Test("Tab order is per-Space, not global")
    func orderIsPerSpace() async {
        let (personal, work) = twoSpaces()
        let (store, _, _) = makeStore(
            tabs: (0..<3).map {
                TabBuilder().url("https://p\($0).example").space(personal.id)
                    .ephemeral(order: $0).build()
            },
            spaces: [personal, work]
        )
        await store.restore()

        store.selectSpace(work.id)  // opens one tab at order 0
        store.newTab(url: URL(string: "https://w2.example")!)

        #expect(store.visibleTabs.map(\.placement.order) == [0, 1])
    }

    @Test("Cmd+1...9 selects by position, and ignores positions that do not exist")
    func selectByIndex() async {
        let (personal, work) = twoSpaces()
        let (store, _, _) = makeStore(spaces: [personal, work])
        await store.restore()

        store.selectSpace(atIndex: 1)
        #expect(store.activeSpace?.id == work.id)

        // Cmd+7 with two Spaces should do nothing, not jump to the last one.
        store.selectSpace(atIndex: 6)
        #expect(store.activeSpace?.id == work.id)
    }

    @Test("Moving a tab to another Space tears down its web view")
    func moveEvictsView() async {
        let (personal, work) = twoSpaces()
        let tab = TabBuilder().space(personal.id).build()
        let (store, engine, _) = makeStore(tabs: [tab], spaces: [personal, work])
        await store.restore()
        _ = store.surface(for: tab)

        store.moveTab(tab.id, toSpace: work.id)

        // The view belonged to Personal's data store; carrying it across would
        // carry Personal's cookies with it.
        #expect(engine.evictedPanes.contains(tab.focusedPaneID))
        #expect(store.tabs.first { $0.id == tab.id }?.spaceID == work.id)
    }

    @Test("Deleting a Space removes its tabs and reclaims its data")
    func deleteSpaceRemovesData() async {
        let (personal, work) = twoSpaces()
        let (store, engine, _) = makeStore(
            tabs: [
                TabBuilder().url("https://p.example").space(personal.id).build(),
                TabBuilder().url("https://w.example").space(work.id).build(),
            ],
            spaces: [personal, work]
        )
        await store.restore()

        await store.deleteSpace(work.id)

        #expect(store.spaces.count == 1)
        #expect(store.tabs.allSatisfy { $0.spaceID == personal.id })
        #expect(engine.removedDataForSpaces == [work.id])
    }

    @Test("The last Space cannot be deleted")
    func lastSpaceSurvives() async {
        let (store, engine, _) = makeStore()
        await store.restore()

        await store.deleteSpace(store.spaces[0].id)

        #expect(store.spaces.count == 1)
        #expect(engine.removedDataForSpaces.isEmpty)
    }

    @Test("Deleting the active Space activates another one")
    func deletingActiveSwitches() async {
        let (personal, work) = twoSpaces()
        let (store, _, _) = makeStore(spaces: [personal, work])
        await store.restore()
        store.selectSpace(work.id)

        await store.deleteSpace(work.id)

        #expect(store.activeSpace?.id == personal.id)
        #expect(store.selectedTabID != nil)
    }

    @Test("A failed data reclaim still removes the Space from view")
    func failedReclaimStillRemoves() async {
        let (personal, work) = twoSpaces()
        let (store, engine, _) = makeStore(spaces: [personal, work])
        await store.restore()
        engine.removeDataError = CancellationError()

        await store.deleteSpace(work.id)

        #expect(store.spaces.count == 1)
    }

    @Test("A tab whose Space is gone is re-homed rather than lost")
    func orphanedTabsAreAdopted() async {
        let personal = Space(name: "Personal", sortIndex: 0)
        let vanished = UUID()
        let (store, _, _) = makeStore(
            tabs: [TabBuilder().url("https://orphan.example").space(vanished).build()],
            spaces: [personal]
        )

        await store.restore()

        // Dropping it would read to the user as data loss.
        #expect(store.tabs.count == 1)
        #expect(store.tabs[0].spaceID == personal.id)
        #expect(store.visibleTabs.count == 1)
    }

    @Test("Restore across several Spaces still creates no web views")
    func restoreStaysLazyAcrossSpaces() async {
        let (personal, work) = twoSpaces()
        let (store, engine, _) = makeStore(
            tabs: (0..<10).map {
                TabBuilder()
                    .url("https://\($0).example")
                    .space($0.isMultiple(of: 2) ? personal.id : work.id)
                    .build()
            },
            spaces: [personal, work]
        )

        await store.restore()

        #expect(store.tabs.count == 10)
        #expect(engine.liveViewCount() == 0)
    }

    @Test("Adding a Space gives it a distinct gradient")
    func addedSpacesLookDifferent() async {
        let (store, _, _) = makeStore()
        await store.restore()

        store.addSpace(name: "Work")

        #expect(store.spaces[0].gradient != store.spaces[1].gradient)
        #expect(store.activeSpace?.name == "Work")  // new Space is activated
    }

    @Test("A custom emoji icon and colour are set and persisted")
    func customAppearance() async {
        let (store, _, repository) = makeStore()
        await store.restore()
        let id = store.spaces[0].id

        store.setSpaceAppearance(id, icon: "🚀", gradient: ["#112233", "#0A1119"])

        #expect(store.spaces[0].iconSymbol == "🚀")
        #expect(store.spaces[0].isEmojiIcon)
        #expect(store.spaces[0].gradient == ["#112233", "#0A1119"])
        // Persisted, not just in memory.
        try? await Task.sleep(for: .milliseconds(50))
        let stored = await repository.storedSpaces.first { $0.id == id }
        #expect(stored?.iconSymbol == "🚀")
    }

    @Test("An empty icon is ignored rather than blanking the Space")
    func emptyIconIgnored() async {
        let (store, _, _) = makeStore()
        await store.restore()
        let id = store.spaces[0].id
        let original = store.spaces[0].iconSymbol

        store.setSpaceAppearance(id, icon: "  ", gradient: [])

        #expect(store.spaces[0].iconSymbol == original)
        #expect(store.spaces[0].gradient == Space.defaultGradient)  // empty falls back
    }
}

@Suite("Space value type")
struct SpaceValueTests {

    @Test("Hex parses into components")
    func hexParses() throws {
        let components = try #require(ColorHex("#5B7FFF").components)
        #expect(abs(components.red - 0x5B / 255.0) < 0.001)
        #expect(abs(components.green - 0x7F / 255.0) < 0.001)
        #expect(abs(components.blue - 1.0) < 0.001)
    }

    @Test("A hex string without the hash still parses")
    func hexWithoutHash() {
        #expect(ColorHex("5B7FFF").components != nil)
    }

    @Test("Malformed hex yields nothing rather than a wrong colour", arguments: [
        "#XYZ", "#12345", "", "#1234567", "not a colour",
    ])
    func malformedHex(input: String) {
        #expect(ColorHex(input).components == nil)
    }

    @Test("A Space survives a Codable round-trip")
    func spaceRoundTrip() throws {
        let original = Space(
            name: "Work",
            iconSymbol: "briefcase",
            gradient: ["#FF7A59", "#FF4D8D"],
            sortIndex: 2,
            isPrivate: true
        )

        let decoded = try JSONDecoder().decode(
            Space.self, from: try JSONEncoder().encode(original)
        )
        #expect(decoded == original)
        #expect(decoded.dataStoreID == original.dataStoreID)
    }

    @Test("The palette cycles rather than running out")
    func paletteCycles() {
        #expect(Space.gradient(forIndex: 0) == Space.gradient(forIndex: Space.palette.count))
        #expect(Space.gradient(forIndex: 99).count == 2)
    }
}
