import ChordCore
import ChordStore
import SwiftUI

/// Runs the horizontal Space-switch animation for the paths that have no
/// gesture behind them — ⌘1…9 and clicking a Space in the switcher (4.2).
///
/// **One mechanism for all three paths.** A trackpad swipe already drives
/// `spaceSwipeProgress` continuously and hands off to a spring on release; this
/// drives the *same* value, so a keyboard switch and a swipe are the same
/// movement and cannot drift apart as either is tuned. Nothing here knows what
/// the progress is used to draw — that is `SidebarView`'s business.
///
/// The switch is two phases, because one is not enough to read as travel:
///
/// 1. spring the outgoing Space out to `±1`,
/// 2. commit — the model changes, and the sidebar now holds the *new* Space —
///    then jump the progress to the far side (`∓1`, unanimated, off screen) and
///    spring it back to rest.
///
/// Without the second phase the new Space appears at rest, which reads as a cut
/// rather than a slide. The jump is invisible precisely because it happens on
/// content that is already off screen.
@MainActor
public enum SpaceSwitchAnimator {

    /// Switches `window` to `spaceID`, sliding. A no-op when it is already
    /// there, when the Space is unknown, or when the window is private (which
    /// is locked to its own Space).
    public static func switchSpace(
        to spaceID: UUID, in window: WindowState, store: TabStore, reduceMotion: Bool
    ) {
        guard window.activeSpaceID != spaceID,
            let target = store.visibleSpaces.first(where: { $0.id == spaceID }),
            !window.isPrivate
        else { return }

        let direction = direction(to: target, in: window, store: store)
        run(direction: direction, reduceMotion: reduceMotion) {
            store.selectSpace(spaceID, in: window)
        } progress: { value in
            store.setSpaceSwipeProgress(value, in: window)
        }
    }

    /// The ⌘1…9 form. Indexes the *visible* Spaces, so a private window's
    /// throwaway Space can never be reached by number.
    public static func switchSpace(
        toIndex index: Int, in window: WindowState, store: TabStore, reduceMotion: Bool
    ) {
        let ordered = store.visibleSpaces.sorted { $0.sortIndex < $1.sortIndex }
        guard ordered.indices.contains(index) else { return }
        switchSpace(to: ordered[index].id, in: window, store: store, reduceMotion: reduceMotion)
    }

    /// Finishes a committed swipe: the gesture has already sprung the outgoing
    /// Space out to `±1`, so only the second phase remains.
    public static func finishSwipe(
        direction: Int, in window: WindowState, store: TabStore, reduceMotion: Bool
    ) {
        store.commitSpaceSwipe(direction: direction, in: window)
        slideIn(direction: direction, reduceMotion: reduceMotion) { value in
            store.setSpaceSwipeProgress(value, in: window)
        }
    }

    /// Positive when the target sits later in the switcher, so the movement
    /// matches the direction the eye expects from the icon order.
    private static func direction(
        to target: Space, in window: WindowState, store: TabStore
    ) -> Int {
        guard let current = store.activeSpace(in: window) else { return 1 }
        return target.sortIndex >= current.sortIndex ? 1 : -1
    }

    private static func run(
        direction: Int,
        reduceMotion: Bool,
        commit: @escaping () -> Void,
        progress: @escaping (Double) -> Void
    ) {
        let animation = Motion.respectingReduceMotion(
            Motion.spaceSwitch, reduceMotion: reduceMotion
        )
        withAnimation(animation) {
            progress(Double(direction))
        } completion: {
            commit()
            slideIn(direction: direction, reduceMotion: reduceMotion, progress: progress)
        }
    }

    /// Phase two: place the newly active Space off screen on the far side, then
    /// spring it to rest.
    private static func slideIn(
        direction: Int, reduceMotion: Bool, progress: @escaping (Double) -> Void
    ) {
        // Unanimated on purpose — this is a teleport of content nobody can see,
        // and animating it would drag the new Space *back* across the window.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { progress(Double(-direction)) }

        withAnimation(Motion.respectingReduceMotion(Motion.spaceSwitch, reduceMotion: reduceMotion)) {
            progress(0)
        }
    }
}
