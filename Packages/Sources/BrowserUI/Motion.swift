import SwiftUI

/// Every duration, spring, and metric in one place so timings can be tuned
/// without hunting through view code (BROWSER_SPEC 5).
public enum Motion {
    public static let tabSelection = Animation.spring(response: 0.28, dampingFraction: 0.86)
    public static let sidebarHover = Animation.easeOut(duration: 0.12)
    public static let progressBar = Animation.easeOut(duration: 0.18)
    /// Sidebar gradient cross-fade on Space switch. Continuous swipe-driven
    /// switching is M6; this is the discrete case.
    public static let spaceSwitch = Animation.spring(response: 0.32, dampingFraction: 0.9)

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
    /// Vertical clearance for the traffic lights under `.hiddenTitleBar`.
    ///
    /// Only the sidebar needs it — the lights sit over the sidebar alone, so
    /// reserving it window-wide leaves a dead band above the web content.
    public static let titlebarInset: CGFloat = 28
    public static let faviconSize: CGFloat = 16
    /// Split view (4.5).
    public static let splitDividerWidth: CGFloat = 6
    public static let splitFocusRingWidth: CGFloat = 2
    public static let shadowRadius: CGFloat = 12
    public static let shadowOpacity: Double = 0.18
}
