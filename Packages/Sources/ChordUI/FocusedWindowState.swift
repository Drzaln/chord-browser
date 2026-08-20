import ChordStore
import SwiftUI

/// Carries the focused window's `WindowState` to the menu bar.
///
/// `Commands` is built once for the whole app, so a menu item cannot capture a
/// particular window's state — it has to ask which window is focused *now*.
/// `@FocusedValue` is the mechanism for that, and it is what replaces the
/// `NSApp.mainWindow` lookups the command actions used to do: those returned
/// whichever window AppKit considered main, which is a guess that happens to be
/// right while there is only one.
///
/// This is not the services-through-the-environment that §3.6 rules out — no
/// service travels here. It is scene-scoped view state going to the one caller
/// that cannot be handed it directly.
public struct FocusedWindowStateKey: FocusedValueKey {
    public typealias Value = WindowState
}

extension FocusedValues {
    public var windowState: WindowState? {
        get { self[FocusedWindowStateKey.self] }
        set { self[FocusedWindowStateKey.self] = newValue }
    }
}
