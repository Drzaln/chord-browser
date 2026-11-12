import Foundation

/// Whether parked tabs are suspended right now (c1k.16).
///
/// Two user choices and one fact. "Always" is the old toggle: suspend any tab
/// nobody can see, as Safari does. "While hidden" suspends them only while no
/// Chord window is on screen (hidden with Cmd-H, minimized, or fully covered),
/// which is where not suspending costs the most (about 45 ms/s of CPU against
/// Safari's 4) and where the display-link spin a suspended tab can cause
/// (c1k.13) was not seen.
///
/// The spin starts when a suspended page is woken by a window activity
/// change, so the order matters on the way back: suspension is dropped when
/// the app says it is *about to* show (`willUnhide`), before WebKit hears the
/// window is visible again. Deminiaturize has no such early signal.
public enum BackgroundTabPolicy {
    public static func suspends(
        always: Bool, whileHidden: Bool, isOccluded: Bool, isAboutToShow: Bool
    ) -> Bool {
        if always { return true }
        return whileHidden && isOccluded && !isAboutToShow
    }
}
