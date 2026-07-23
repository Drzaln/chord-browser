import Foundation
import Testing

@testable import BrowserCore

@Suite("Split-view fraction maths")
struct SplitLayoutTests {

    /// The invariant everything else depends on: a tab's panes always cover
    /// exactly the tab, never more and never less.
    private func expectSumsToOne(_ fractions: [Double], _ label: String = "") {
        let total = fractions.reduce(0, +)
        #expect(abs(total - 1.0) < 0.000_001, "\(label) summed to \(total)")
    }

    @Test("An equal split covers the whole width", arguments: 1...SplitLayout.maxPanes)
    func equalSplitSumsToOne(count: Int) {
        let fractions = SplitLayout.equalFractions(count: count)
        #expect(fractions.count == count)
        expectSumsToOne(fractions, "equal split of \(count)")
    }

    @Test("Normalizing preserves proportions")
    func normalizePreservesProportions() {
        // Two panes left after closing a third: one was twice the other, and
        // should stay twice the other.
        let normalized = SplitLayout.normalized([0.2, 0.4])

        expectSumsToOne(normalized)
        #expect(abs(normalized[1] / normalized[0] - 2.0) < 0.000_001)
    }

    @Test("Normalizing degenerate input falls back to an equal split")
    func normalizeDegenerate() {
        // Never divide by zero and never emit NaN — a NaN width would take the
        // whole layout down, not just one pane.
        expectSumsToOne(SplitLayout.normalized([0, 0, 0]))
        expectSumsToOne(SplitLayout.normalized([-1, -1]))
    }

    @Test("Dragging a divider moves width between two neighbours only")
    func dragMovesOnlyNeighbours() {
        let start = SplitLayout.equalFractions(count: 3)
        let moved = SplitLayout.resizing(start, dividerAfter: 0, by: 0.1)

        expectSumsToOne(moved)
        #expect(abs(moved[0] - (start[0] + 0.1)) < 0.000_001)
        #expect(abs(moved[1] - (start[1] - 0.1)) < 0.000_001)
        // The third pane is not adjacent to this divider and must not move.
        #expect(moved[2] == start[2])
    }

    @Test("A drag cannot collapse a pane below the minimum")
    func dragClampsAtMinimum() {
        let start = SplitLayout.equalFractions(count: 2)

        // Shove the divider far past the right-hand pane's minimum.
        let moved = SplitLayout.resizing(start, dividerAfter: 0, by: 5.0)

        expectSumsToOne(moved)
        #expect(moved[1] >= SplitLayout.minimumFraction - 0.000_001)
        #expect(moved[0] <= 1.0 - SplitLayout.minimumFraction + 0.000_001)
    }

    @Test("Dragging the other way clamps too")
    func dragClampsAtMinimumReversed() {
        let moved = SplitLayout.resizing(SplitLayout.equalFractions(count: 2),
                                         dividerAfter: 0, by: -5.0)

        expectSumsToOne(moved)
        #expect(moved[0] >= SplitLayout.minimumFraction - 0.000_001)
    }

    @Test("An out-of-range divider index is ignored")
    func outOfRangeDividerIsIgnored() {
        let start = SplitLayout.equalFractions(count: 2)
        #expect(SplitLayout.resizing(start, dividerAfter: 1, by: 0.1) == start)
        #expect(SplitLayout.resizing(start, dividerAfter: -1, by: 0.1) == start)
    }

    @Test("Repeated drags never drift off 1.0")
    func repeatedDragsStaySummed() {
        // A real drag emits a stream of small deltas; rounding must not
        // accumulate into panes that no longer cover the tab.
        var fractions = SplitLayout.equalFractions(count: 4)
        for step in 0..<200 {
            fractions = SplitLayout.resizing(
                fractions, dividerAfter: step % 3, by: step.isMultiple(of: 2) ? 0.013 : -0.017
            )
        }
        expectSumsToOne(fractions, "after 200 drags")
        #expect(fractions.allSatisfy { $0 >= SplitLayout.minimumFraction - 0.000_001 })
    }
}
