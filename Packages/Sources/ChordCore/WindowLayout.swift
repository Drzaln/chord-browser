import Foundation

/// The layout of one browser window, captured so a relaunch can put each window
/// back on the Space and tab it was showing.
///
/// macOS scene restoration decides *how many* windows come back and recreates
/// their frames; what it cannot know is Chord's world — which Space and which tab
/// each was looking at. That is what this persists. Windows have no durable
/// identity of their own, so the ordinal *is* the identity: layouts are saved in
/// window order (the primary first) and handed back in claim order.
///
/// A layout is window *state*, not user data — losing one costs a window its
/// remembered Space, never a tab. So it is decoded defensively and a missing or
/// stale reference simply falls back to a reconcile, never a failed launch.
public struct WindowLayout: Sendable, Equatable, Identifiable {
    /// Position in window order, the primary at 0. Doubles as the row key.
    public let ordinal: Int
    /// The Space the window was showing, if it still resolves at restore.
    public let activeSpaceID: UUID?
    /// The tab the window was showing, if it still resolves and is free.
    public let selectedTabID: UUID?

    public var id: Int { ordinal }

    public init(ordinal: Int, activeSpaceID: UUID?, selectedTabID: UUID?) {
        self.ordinal = ordinal
        self.activeSpaceID = activeSpaceID
        self.selectedTabID = selectedTabID
    }
}
