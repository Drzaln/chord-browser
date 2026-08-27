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

    /// Sidebar collapse and hover-expand (4.1). One spring for both, so the
    /// rail leaving and the overlay arriving read as the same movement.
    public static let sidebarCollapse = Animation.spring(response: 0.30, dampingFraction: 0.86)

    /// The top-right action-confirmation toast (non-spec: user-requested).
    public static let toast = Animation.spring(response: 0.25, dampingFraction: 0.9)

    /// How long the pointer must be off the expanded overlay before it
    /// re-collapses. Zero makes the sidebar flicker shut while you travel from
    /// a row to the page; too long and it feels stuck open.
    public static let sidebarCollapseDelay: Duration = .milliseconds(220)

    /// Little Chord's scale-and-fade in from the cursor (4.6). Driven by
    /// `NSAnimationContext` rather than SwiftUI, because it animates a window
    /// frame, so these are plain numbers rather than an `Animation`.
    public static let littleChordEntryDuration: TimeInterval = 0.22
    public static let littleChordEntryScale: CGFloat = 0.86

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
    /// A favourite's tile in the pinned grid (4.1).
    public static let pinnedTileHeight: CGFloat = 44
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
    public static let splitDropRingWidth: CGFloat = 3
    /// Little Chord (4.6).
    public static let littleChordCornerRadius: CGFloat = 12
    public static let shadowRadius: CGFloat = 12
    public static let shadowOpacity: Double = 0.18
}
