import BrowserCore
import BrowserEngine
import BrowserStore
import BrowserTestSupport
import Foundation
import Testing

@Suite("Print")
@MainActor
struct PrintTests {

    @Test("Print targets the selected tab's focused pane")
    func printsFocusedPane() async {
        let engine = FakeWebEngine()
        let tab = TabBuilder().url("https://a.example")
            .extraPane(url: "https://b.example").build()
        let repository = FakeTabRepository(stored: [tab], spaces: [TabBuilder.defaultSpace()])
        let store = TabStore(
            engine: engine, repository: repository,
            spaceRepository: repository, clock: FixedClock()
        )
        await store.restore()
        store.select(tab.id)

        store.printSelectedPane()

        #expect(engine.printedPanes == [tab.focusedPaneID])
    }

    @Test("Print with no selection does nothing")
    func printsNothingWithoutSelection() {
        let engine = FakeWebEngine()
        let repository = FakeTabRepository(stored: [], spaces: [])
        let store = TabStore(
            engine: engine, repository: repository,
            spaceRepository: repository, clock: FixedClock()
        )
        store.printSelectedPane()
        #expect(engine.printedPanes.isEmpty)
    }
}
