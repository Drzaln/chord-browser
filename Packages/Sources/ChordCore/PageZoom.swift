import Foundation

/// Full-page zoom levels (non-spec: user-requested), matching the discrete
/// ladder every Chromium-family browser and Safari expose via Cmd+/-/0.
///
/// `WKWebView.pageZoom` is a plain `CGFloat` scale factor (1.0 = 100%), so this
/// is just the policy for which values are reachable and what +/- step to. Pure
/// and `Sendable` so it lives in `ChordCore` and stays unit-testable; the
/// WebKit application of the factor happens in the engine.
public enum PageZoom {
    /// The discrete ladder, from the platform's "actual size" at 1.0 outward in
    /// both directions. Clamped to this range, never extrapolated.
    public static let steps: [Double] = [
        0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1.0,
        1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0,
    ]

    /// The "Actual Size" reset target and the default.
    public static let defaultFactor: Double = 1.0

    public static let minFactor: Double = 0.25
    public static let maxFactor: Double = 5.0

    /// Normalises a stored/persisted factor onto the ladder's range. A stored
    /// value is trusted to be *valid* (on the ladder) but not *sane*, so an
    /// out-of-range read clamps rather than misapplies.
    public static func clamped(_ value: Double) -> Double {
        min(max(value, minFactor), maxFactor)
    }

    /// The next rung above `current`, or `current` when already at the top.
    public static func zoomIn(_ current: Double) -> Double {
        let c = clamped(current)
        return steps.first(where: { $0 > c + 0.000_1 }) ?? c
    }

    /// The next rung below `current`, or `current` when already at the bottom.
    public static func zoomOut(_ current: Double) -> Double {
        let c = clamped(current)
        return steps.last(where: { $0 < c - 0.000_1 }) ?? c
    }
}
