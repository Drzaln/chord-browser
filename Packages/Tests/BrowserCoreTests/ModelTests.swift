import BrowserCore
import BrowserTestSupport
import Foundation
import Testing

@Suite("Model round-trips")
struct ModelCodableTests {

    @Test("Tab survives a Codable round-trip")
    func tabRoundTrip() throws {
        let original = TabBuilder()
            .url("https://example.com/page")
            .title("Example")
            .pinned(order: 3)
            .favicon(Data([0x01, 0x02, 0x03]))
            .extraPane(url: "https://example.org", widthFraction: 0.4)
            .build()

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Tab.self, from: data)

        #expect(decoded == original)
        #expect(decoded.panes.count == 2)
        #expect(decoded.focusedPaneID == original.focusedPaneID)
    }

    @Test("TabPlacement preserves its case and order")
    func placementRoundTrip() throws {
        for placement in [TabPlacement.pinned(order: 2), .ephemeral(order: 7)] {
            let data = try JSONEncoder().encode(placement)
            let decoded = try JSONDecoder().decode(TabPlacement.self, from: data)
            #expect(decoded == placement)
            #expect(decoded.order == placement.order)
        }
    }

    @Test("Only pinned placement reports isPinned")
    func isPinned() {
        #expect(TabPlacement.pinned(order: 0).isPinned)
        #expect(!TabPlacement.ephemeral(order: 0).isPinned)
    }

    @Test("withOrder changes the order without changing the case")
    func withOrder() {
        #expect(TabPlacement.pinned(order: 1).withOrder(5) == .pinned(order: 5))
        #expect(TabPlacement.ephemeral(order: 1).withOrder(5) == .ephemeral(order: 5))
    }
}

@Suite("Display titles")
struct DisplayTitleTests {

    @Test("A titled pane shows its title")
    func usesTitle() {
        let tab = TabBuilder().title("Hacker News").build()
        #expect(tab.displayTitle == "Hacker News")
    }

    @Test("An untitled pane falls back to the host, not the full URL")
    func fallsBackToHost() {
        let tab = TabBuilder().url("https://news.ycombinator.com/item?id=1").build()
        #expect(tab.displayTitle == "news.ycombinator.com")
    }

    @Test("A hostless URL falls back to the whole string")
    func fallsBackToString() {
        let pane = Pane(url: URL(string: "about:blank")!)
        #expect(pane.displayTitle == "about:blank")
    }
}

@Suite("Focused pane")
struct FocusedPaneTests {

    @Test("A tab with a dangling focus id still returns a pane")
    func danglingFocusFallsBack() {
        var tab = TabBuilder().build()
        tab.focusedPaneID = UUID()
        #expect(tab.focusedPane.id == tab.panes[0].id)
    }

    @Test("updatePane mutates only the addressed pane")
    func updatesOnlyTarget() {
        var tab = TabBuilder().extraPane(url: "https://example.org").build()
        let targetID = tab.panes[1].id

        tab.updatePane(targetID) { $0.title = "changed" }

        #expect(tab.panes[0].title.isEmpty)
        #expect(tab.panes[1].title == "changed")
    }

    @Test("updatePane on an unknown id is a no-op")
    func unknownPaneIsNoOp() {
        var tab = TabBuilder().title("original").build()
        tab.updatePane(UUID()) { $0.title = "changed" }
        #expect(tab.panes[0].title == "original")
    }
}
