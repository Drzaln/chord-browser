import Foundation
import Testing

@testable import ChordEngine

@Suite("Back-swipe monitor")
struct BackSwipeMonitorTests {

    @Test("A committed rightward swipe with no history closes")
    func commitsWithNoHistory() {
        #expect(BackSwipeDecision.commit(dx: 80, dy: 5, couldGoBack: false))
    }

    @Test("A rightward swipe with history is left to WebKit")
    func leavesWebKitToNavigate() {
        #expect(!BackSwipeDecision.commit(dx: 80, dy: 5, couldGoBack: true))
    }

    @Test("A short, leftward, or mostly-vertical swipe does not close")
    func rejectsNonBackSwipes() {
        #expect(!BackSwipeDecision.commit(dx: 40, dy: 5, couldGoBack: false))
        #expect(!BackSwipeDecision.commit(dx: -80, dy: 5, couldGoBack: false))
        #expect(!BackSwipeDecision.commit(dx: 80, dy: 60, couldGoBack: false))
        #expect(!BackSwipeDecision.commit(dx: 0, dy: 0, couldGoBack: false))
    }
}
