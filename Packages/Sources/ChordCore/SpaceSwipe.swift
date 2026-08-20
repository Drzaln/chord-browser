import Foundation

/// Pure maths for the two-finger swipe that switches Spaces (4.2).
///
/// The gesture itself is raw `NSEvent` scroll-phase handling in the UI layer —
/// a recogniser cannot track a swipe continuously, which is the whole feel being
/// copied. Everything here is the part that can be reasoned about without a
/// trackpad: how far a swipe must travel to commit, how it resists past the
/// ends, and how the gradient blends on the way.
public enum SpaceSwipe {
    /// Points of horizontal travel that map to a full one-Space transition.
    public static let fullSwipeDistance: Double = 260

    /// Fraction of a full swipe that commits to the neighbour on release.
    /// Below this, the swipe springs back to where it started.
    public static let commitThreshold: Double = 0.5

    /// Normalises accumulated horizontal travel (points) into a signed progress
    /// fraction. Positive is toward the next Space (higher `sortIndex`).
    public static func progress(forOffset offset: Double) -> Double {
        offset / fullSwipeDistance
    }

    /// Rubber-band resistance for a swipe past the first or last Space, so the
    /// ends feel like a wall you can lean on but not cross. Maps `[0, ∞)` with
    /// diminishing return onto `[0, maxRubberBand)` — capped strictly below
    /// `commitThreshold` so an end never looks like it is about to switch, à la
    /// `UIScrollView`.
    public static let maxRubberBand: Double = 0.45

    public static func rubberBand(_ magnitude: Double) -> Double {
        let m = max(0, magnitude)
        return maxRubberBand * (1 - 1 / (m * 0.55 + 1))
    }

    /// Blends two gradient stop arrays colour-for-colour. Unequal lengths are
    /// padded with the shorter array's last stop, so the blend never changes the
    /// number of stops partway through and pops.
    public static func blend(_ from: [ColorHex], _ to: [ColorHex], t: Double) -> [ColorHex] {
        guard !from.isEmpty, !to.isEmpty else { return from }
        let count = max(from.count, to.count)
        return (0..<count).map { i in
            let a = from[min(i, from.count - 1)]
            let b = to[min(i, to.count - 1)]
            return ColorHex.lerp(a, b, t: t)
        }
    }
}
