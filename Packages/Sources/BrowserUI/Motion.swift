import SwiftUI

/// Every duration, spring, and metric in one place so timings can be tuned
/// without hunting through view code (BROWSER_SPEC 5).
public enum Motion {
    public static let tabSelection = Animation.spring(response: 0.28, dampingFraction: 0.86)
    public static let sidebarHover = Animation.easeOut(duration: 0.12)
    public static let progressBar = Animation.easeOut(duration: 0.18)

    /// Honour Reduce Motion by collapsing to a cross-fade rather than dropping
    /// feedback entirely.
    public static func respectingReduceMotion(
        _ animation: Animation, reduceMotion: Bool
    ) -> Animation {
        reduceMotion ? .linear(duration: 0.01) : animation
    }
}

public enum Metrics {
    public static let sidebarWidth: CGFloat = 240
    public static let sidebarRowHeight: CGFloat = 30
    public static let contentCornerRadius: CGFloat = 10
    public static let contentInset: CGFloat = 8
    public static let faviconSize: CGFloat = 16
    public static let shadowRadius: CGFloat = 12
    public static let shadowOpacity: Double = 0.18
}
