import ChordCore
import ChordTestSupport
import Foundation
import Testing

@testable import ChordPersistence

/// Persistence is the one subsystem where a bug costs data rather than a
/// reload, so decoding is tested against deliberately broken rows (3.7).
@Suite("Defensive row decoding")
struct MappingTests {

    private func validTabRow(
        id: String = UUID().uuidString,
        spaceId: String = TabBuilder.defaultSpaceID.uuidString
    ) -> TabRow {
        TabRow(
            id: id,
            spaceId: spaceId,
            placementKind: "ephemeral",
            placementOrder: 0,
            focusedPaneID: UUID().uuidString,
            lastAccessedAt: 1_700_000_000,
            createdAt: 1_700_000_000
        )
    }

    private func validPaneRow(tabId: String, id: String = UUID().uuidString) -> PaneRow {
        PaneRow(
            id: id,
            tabId: tabId,
            position: 0,
            url: "https://example.com",
            title: "Example",
            customTitle: nil,
            faviconData: nil,
            widthFraction: 1.0
        )
    }

    @Test("A tab with an unparseable id is skipped, not thrown")
    func badTabID() {
        let row = validTabRow(id: "not-a-uuid")
        let pane = validPaneRow(tabId: row.id)
        #expect(TabMapping.model(tabRow: row, paneRows: [pane]) == nil)
    }

    @Test("A tab with an unparseable spaceId is skipped")
    func badSpaceID() {
        let row = validTabRow(spaceId: "not-a-uuid")
        #expect(TabMapping.model(tabRow: row, paneRows: [validPaneRow(tabId: row.id)]) == nil)
    }

    @Test("A tab carries its Space through the round-trip")
    func spaceRoundTrip() throws {
        let spaceID = UUID()
        let row = validTabRow(spaceId: spaceID.uuidString)

        let tab = try #require(
            TabMapping.model(tabRow: row, paneRows: [validPaneRow(tabId: row.id)])
        )
        #expect(tab.spaceID == spaceID)
        #expect(TabMapping.rows(for: tab).tab.spaceId == spaceID.uuidString)
    }

    @Test("A tab with an unknown placement kind is skipped")
    func unknownPlacement() {
        var row = validTabRow()
        row.placementKind = "archived"
        #expect(TabMapping.model(tabRow: row, paneRows: [validPaneRow(tabId: row.id)]) == nil)
    }

    @Test("A tab whose panes are all unusable is skipped")
    func noUsablePanes() {
        let row = validTabRow()
        var pane = validPaneRow(tabId: row.id)
        pane.id = "not-a-uuid"
        #expect(TabMapping.model(tabRow: row, paneRows: [pane]) == nil)
    }

    @Test("One bad pane does not take the whole tab down")
    func oneBadPaneIsDropped() throws {
        let row = validTabRow()
        var good = validPaneRow(tabId: row.id)
        good.position = 0
        var bad = validPaneRow(tabId: row.id)
        bad.id = "not-a-uuid"
        bad.position = 1

        let tab = try #require(TabMapping.model(tabRow: row, paneRows: [good, bad]))
        #expect(tab.panes.count == 1)
    }

    @Test("A dangling focus pointer falls back to the first pane")
    func danglingFocus() throws {
        var row = validTabRow()
        row.focusedPaneID = UUID().uuidString  // points at no pane
        let pane = validPaneRow(tabId: row.id)

        let tab = try #require(TabMapping.model(tabRow: row, paneRows: [pane]))
        #expect(tab.focusedPaneID == tab.panes[0].id)
    }

    @Test("A valid focus pointer is honoured")
    func validFocusHonoured() throws {
        var row = validTabRow()
        var first = validPaneRow(tabId: row.id)
        first.position = 0
        var second = validPaneRow(tabId: row.id)
        second.position = 1
        row.focusedPaneID = second.id

        let tab = try #require(TabMapping.model(tabRow: row, paneRows: [first, second]))
        #expect(tab.focusedPaneID.uuidString == second.id)
    }

    @Test("Panes are ordered by position, not by row order")
    func panesSortedByPosition() throws {
        let row = validTabRow()
        var first = validPaneRow(tabId: row.id)
        first.position = 0
        first.url = "https://first.example"
        var second = validPaneRow(tabId: row.id)
        second.position = 1
        second.url = "https://second.example"

        let tab = try #require(TabMapping.model(tabRow: row, paneRows: [second, first]))
        #expect(tab.panes.map { $0.url.host() } == ["first.example", "second.example"])
    }

    @Test("Model to rows assigns contiguous positions")
    func rowsGetPositions() {
        let tab = TabBuilder()
            .extraPane(url: "https://b.example")
            .extraPane(url: "https://c.example")
            .build()

        let (_, paneRows) = TabMapping.rows(for: tab)
        #expect(paneRows.map(\.position) == [0, 1, 2])
    }

    @Test("A user-renamed tab survives the row round-trip")
    func customTitleRoundTrip() throws {
        let tab = TabBuilder()
            .title("Page Title")
            .customTitle("Work")
            .build()

        let (_, paneRows) = TabMapping.rows(for: tab)
        let rebuilt = try #require(TabMapping.model(tabRow: TabMapping.rows(for: tab).tab, paneRows: paneRows))

        #expect(rebuilt.displayTitle == "Work")
        #expect(rebuilt.customTitle == "Work")
        #expect(rebuilt.panes[0].title == "Page Title")
    }
}
