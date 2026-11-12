import Foundation
import Testing

@testable import ChordStore

/// gn0.11: arrow keys walk the sidebar's tab rows with a cursor of their own.
@Suite("Sidebar keyboard navigation")
struct SidebarNavigationTests {
    let a = UUID(), b = UUID(), c = UUID()
    var order: [UUID] { [a, b, c] }

    @Test func theFirstPressLandsOnTheSelectedTab() {
        #expect(SidebarNavigation.move(from: nil, selected: b, in: order, by: 1) == b)
        #expect(SidebarNavigation.move(from: nil, selected: b, in: order, by: -1) == b)
    }

    @Test func withNothingSelectedDownStartsAtTheTopAndUpAtTheBottom() {
        #expect(SidebarNavigation.move(from: nil, selected: nil, in: order, by: 1) == a)
        #expect(SidebarNavigation.move(from: nil, selected: nil, in: order, by: -1) == c)
    }

    @Test func itMovesOneRowAndStopsAtTheEnds() {
        #expect(SidebarNavigation.move(from: a, selected: c, in: order, by: 1) == b)
        #expect(SidebarNavigation.move(from: b, selected: c, in: order, by: -1) == a)
        #expect(SidebarNavigation.move(from: a, selected: c, in: order, by: -1) == a)
        #expect(SidebarNavigation.move(from: c, selected: a, in: order, by: 1) == c)
    }

    @Test func aCursorOnARowThatIsGoneStartsAgainFromTheSelection() {
        #expect(SidebarNavigation.move(from: UUID(), selected: b, in: order, by: 1) == b)
    }

    @Test func anEmptyListHasNoCursor() {
        #expect(SidebarNavigation.move(from: a, selected: a, in: [], by: 1) == nil)
    }

    @Test func closingARowMovesTheCursorToItsNeighbour() {
        #expect(SidebarNavigation.afterClosing(b, in: order) == c)
        #expect(SidebarNavigation.afterClosing(c, in: order) == b)
        #expect(SidebarNavigation.afterClosing(a, in: [a]) == nil)
        #expect(SidebarNavigation.afterClosing(UUID(), in: order) == nil)
    }
}
