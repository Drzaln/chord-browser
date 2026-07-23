import Foundation
import Observation

/// Signals the reused command bar view that it is being shown again.
///
/// The panel and its SwiftUI view are built once and reused, so `onAppear`
/// fires exactly once in the app's lifetime. Without a token like this, the
/// second `Cmd+T` shows a bar that still holds the previous query and never
/// takes keyboard focus.
@MainActor
@Observable
final class CommandBarSession {
    /// Incremented on every present. The view resets and focuses on change.
    private(set) var presentToken = 0

    /// Incremented when something outside the SwiftUI view asks for the
    /// highlighted result to be opened.
    private(set) var activateToken = 0
    private(set) var activateForcesNewTab = false

    func beginPresentation() {
        presentToken += 1
    }

    /// Used by the panel's key-equivalent handling: a focused `TextField`
    /// swallows Return and ignores Cmd+Return outright, so Cmd+Enter has to be
    /// caught in AppKit and routed back into the view (4.4).
    func requestActivate(forceNewTab: Bool) {
        activateForcesNewTab = forceNewTab
        activateToken += 1
    }
}
