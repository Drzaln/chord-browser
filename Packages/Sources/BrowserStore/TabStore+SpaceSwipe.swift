import BrowserCore
import Foundation

/// Swipe-driven Space switching (4.2). Split from `TabStore.swift` to keep both
/// under the ~400-line limit (7.6).
///
/// The store owns only the *state* of a swipe and the decision to commit; the
/// gesture — raw scroll-phase `NSEvent` handling — lives in `SpaceSwipeMonitor`
/// in the UI layer, which feeds accumulated travel here and drives the release
/// spring. This split keeps the commit logic testable without a trackpad.
@MainActor
extension TabStore {

    /// Spaces in switch order.
    var orderedSpaces: [Space] {
        spaces.sorted { $0.sortIndex < $1.sortIndex }
    }

    private func activeSpaceIndex(in window: WindowState) -> Int? {
        guard let id = activeSpace(in: window)?.id else { return nil }
        return orderedSpaces.firstIndex { $0.id == id }
    }

    /// The Space one step from the window's. `direction` is +1 for the next
    /// Space (higher `sortIndex`), -1 for the previous.
    func neighbourSpace(direction: Int, in window: WindowState? = nil) -> Space? {
        guard let index = activeSpaceIndex(in: window ?? primaryWindow) else { return nil }
        let target = index + direction
        return orderedSpaces.indices.contains(target) ? orderedSpaces[target] : nil
    }

    /// Whether a swipe in `direction` has somewhere to go. False at the ends,
    /// which is what makes the swipe rubber-band rather than commit there.
    public func canSwipeSpace(direction: Int, in window: WindowState? = nil) -> Bool {
        neighbourSpace(direction: direction, in: window ?? primaryWindow) != nil
    }

    // MARK: - Driving a swipe

    public func beginSpaceSwipe(in window: WindowState? = nil) {
        (window ?? primaryWindow).spaceSwipeProgress = 0
    }

    /// Sets the progress directly. The release spring lives in the UI's
    /// `SpaceSwipeMonitor`, which drives this inside `withAnimation`.
    public func setSpaceSwipeProgress(_ value: Double, in window: WindowState? = nil) {
        (window ?? primaryWindow).spaceSwipeProgress = value
    }

    /// `offset` is accumulated horizontal travel in points, positive toward the
    /// next Space. Past the last (or before the first) Space there is no
    /// neighbour, so the progress rubber-bands instead of tracking one-to-one.
    public func updateSpaceSwipe(offset: Double, in window: WindowState? = nil) {
        let window = window ?? primaryWindow
        let raw = SpaceSwipe.progress(forOffset: offset)
        let direction = raw >= 0 ? 1 : -1

        if canSwipeSpace(direction: direction, in: window) {
            window.spaceSwipeProgress = max(-1, min(1, raw))
        } else {
            window.spaceSwipeProgress = Double(direction) * SpaceSwipe.rubberBand(abs(raw))
        }
    }

    /// The swipe crossed the commit threshold toward an existing neighbour.
    public func swipeShouldCommit(in window: WindowState? = nil) -> Bool {
        let window = window ?? primaryWindow
        let progress = window.spaceSwipeProgress
        let direction = progress >= 0 ? 1 : -1
        return abs(progress) >= SpaceSwipe.commitThreshold
            && canSwipeSpace(direction: direction, in: window)
    }

    /// Lands the swipe on the neighbour and resets progress. The caller has
    /// already animated `spaceSwipeProgress` to `±1`, so the blended gradient
    /// there equals the neighbour's fully — resetting to 0 over the *new* active
    /// Space shows the same pixels, and the transition reads as continuous.
    public func commitSpaceSwipe(direction: Int, in window: WindowState? = nil) {
        let window = window ?? primaryWindow
        if let neighbour = neighbourSpace(direction: direction, in: window) {
            selectSpace(neighbour.id, in: window)
        }
        window.spaceSwipeProgress = 0
    }

    // MARK: - Rendering

    /// The gradient stops the sidebar should paint right now: the active Space's,
    /// blended toward the neighbour by the current swipe progress. Returns the
    /// active Space's stops unchanged when no swipe is in flight, so the idle
    /// path stays on `SpaceTheme`'s cache rather than blending every frame.
    public func swipeBlendedGradient(in window: WindowState? = nil) -> [ColorHex] {
        let window = window ?? primaryWindow
        guard let active = activeSpace(in: window) else { return Space.defaultGradient }
        let progress = window.spaceSwipeProgress
        guard progress != 0 else { return active.gradient }

        let direction = progress >= 0 ? 1 : -1
        guard let neighbour = neighbourSpace(direction: direction, in: window) else {
            return active.gradient
        }
        return SpaceSwipe.blend(active.gradient, neighbour.gradient, t: abs(progress))
    }
}
