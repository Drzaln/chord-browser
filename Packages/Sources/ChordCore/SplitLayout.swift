import Foundation

/// Width arithmetic for split view (4.5).
///
/// Pure and dependency-free, so the fraction maths is testable without a view,
/// a web engine, or a drag gesture — the fractions must always sum to 1.0, and
/// that is far easier to prove here than through a divider drag.
public enum SplitLayout {

    /// 4.5: up to four panes in one tab.
    public static let maxPanes = 4

    /// A pane narrower than this is unusable, so a drag stops rather than
    /// collapsing it. Expressed as a fraction of the tab's width.
    public static let minimumFraction = 0.15

    /// Fractions for `count` panes sharing the width equally.
    public static func equalFractions(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        return Array(repeating: 1.0 / Double(count), count: count)
    }

    /// Rescales `fractions` so they sum to 1.0, preserving their proportions.
    ///
    /// Used after a pane is removed: the survivors keep their relative sizes
    /// rather than snapping back to equal, which is what the eye expects.
    public static func normalized(_ fractions: [Double]) -> [Double] {
        guard !fractions.isEmpty else { return [] }

        let positives = fractions.map { max($0, 0) }
        let total = positives.reduce(0, +)

        // Degenerate input (all zero, or negative) has no proportions worth
        // preserving, so fall back to an equal split rather than dividing by 0.
        guard total > 0 else { return equalFractions(count: fractions.count) }

        return positives.map { $0 / total }
    }

    /// Moves the divider between pane `index` and `index + 1` by `delta`
    /// (a fraction of total width), leaving every other pane untouched.
    ///
    /// Only the two adjacent panes resize — dragging one divider must not
    /// cascade a shuffle through the whole tab. The move is clamped so neither
    /// neighbour drops below `minimumFraction`.
    public static func resizing(
        _ fractions: [Double], dividerAfter index: Int, by delta: Double
    ) -> [Double] {
        guard fractions.indices.contains(index),
              fractions.indices.contains(index + 1)
        else { return fractions }

        let left = fractions[index]
        let right = fractions[index + 1]

        // The pair's combined width is fixed; the divider only decides how it
        // is shared. Clamping to this range is what enforces the minimum.
        let lowerBound = minimumFraction - left
        let upperBound = right - minimumFraction
        guard upperBound >= lowerBound else { return fractions }

        let applied = min(max(delta, lowerBound), upperBound)

        var result = fractions
        result[index] = left + applied
        result[index + 1] = right - applied
        return result
    }
}
